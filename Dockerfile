# syntax=docker/dockerfile:1

# Comments are provided throughout this file to help you get started.
# If you need more help, visit the Dockerfile reference guide at
# https://docs.docker.com/engine/reference/builder/

ARG PYTHON_VERSION=3.12
ARG UV_VERSION=0.7
ARG JUPYTER_VERSION=2025-04-14

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv_image

FROM python:${PYTHON_VERSION}-slim AS base

# Keeps Python from buffering stdout and stderr to avoid situations where
# the application crashes without emitting any logs due to buffering.
ENV PYTHONUNBUFFERED=1
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    UV_LINK_MODE=copy \
    UV_FROZEN=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv

# Create a non-privileged user.
# See https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#user
ARG UID=1000
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    nomad


# Final stage to create the runnable image with minimal size
FROM base AS base_final

WORKDIR /app

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
       libgomp1 \
       libmagic1 \
       curl \
       zip \
       unzip \
       nodejs \
       npm \
       && npm install -g configurable-http-proxy@^4.2.0 \
       # clean cache and logs
       && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Activate the virtualenv in the container
# See here for more information:
# https://pythonspeed.com/articles/multi-stage-docker-python/
ENV PATH="/opt/venv/bin:$PATH"


FROM base AS builder

# Prevents Python from writing pyc files.
ENV PYTHONDONTWRITEBYTECODE=1

ENV RUNTIME=docker

WORKDIR /app

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      gcc \
      build-essential \
      curl \
      zip \
      unzip \
      git \
 && rm -rf /var/lib/apt/lists/*

# Install UV
COPY --from=uv_image /uv /bin/uv

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=source=.git,target=.git,type=bind \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --extra plugins

# TEMPORARY: nomad-lab's suggestion-indexing code silently drops autocomplete
# data for any quantity reached through a reference field (authors.name,
# datasets.dataset_name, writers.name, viewers.name, main_author.name) -
# section.m_path() reports the referenced object's own path instead of the
# path it was reached through, so the suggestion value gets written to a
# bogus top-level key instead of nested where Elasticsearch expects it.
# Reported upstream: <link to Discord post / issue once filed>
# Remove this once nomad-lab ships a fix.
RUN python3 <<'PY'
import pathlib, sysconfig

target = pathlib.Path(sysconfig.get_paths()['purelib']) / 'nomad/metainfo/elasticsearch_extension.py'

original = "                        section_path = section.m_path()[len(root.m_path()) :]\n"
patch = (
    original
    + "                        if not section_path or section_path == '/':\n"
    + "                            path_parts = path.rsplit('/', 1)\n"
    + "                            if len(path_parts) == 2 and path_parts[1] == quantity.name:\n"
    + "                                section_path = path_parts[0]\n"
    + "                            else:\n"
    + "                                section_path = path\n"
)

text = target.read_text()
count = text.count(original)
assert count == 1, (
    f"Expected exactly 1 occurrence of the target line in {target}, found {count}. "
    "nomad-lab's elasticsearch_extension.py has likely changed - update or drop this patch."
)
target.write_text(text.replace(original, patch, 1))
print(f"Patched {target}")
PY


COPY scripts ./scripts

FROM builder AS gui_builder

WORKDIR /app

# TEMPORARY: nomad-lab ships a pre-built GUI bundle inside its PyPI wheel
# (see MANIFEST.in: `graft nomad/app/static`) with no source to patch in
# place. This rebuilds the GUI from nomad-FAIR source, at the tag matching
# the nomad-lab version this image installs, with our own app's menu wired
# in as the shared default search context (used by the dataset view, the
# upload management page, section-picker dialogs, the saved-query editor,
# and the sample history card - none of these are app-aware in nomad-lab
# today, they all hardcode the generic "Entries" menu otherwise).
# Remove this once nomad-lab supports per-app context for these pages.
RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      nodejs \
      npm \
 && rm -rf /var/lib/apt/lists/*

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    set -ex && \
    NOMAD_VERSION=$(python3 -c "import importlib.metadata; print(importlib.metadata.version('nomad-lab'))") && \
    NOMAD_TAG="v$(echo "$NOMAD_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')" && \
    echo "Building GUI from nomad-FAIR tag: $NOMAD_TAG (nomad-lab version: $NOMAD_VERSION)" && \
    git clone --depth 1 --branch "$NOMAD_TAG" --filter=blob:none --sparse \
        https://gitlab.mpcdf.mpg.de/nomad-lab/nomad-FAIR.git gui-src && \
    git -C gui-src sparse-checkout set gui

RUN python3 <<'PY'
import json, pathlib
from nomad.cli import cli  # trigger plugin bootstrap
import ccpnc_oasis_app.apps as m

d = m.app_entry_point.app.model_dump(mode='json', exclude_none=True)
# UserdataPage.js and SectionSelectDialog.js mutate context.search_syntaxes.exclude
# directly and assume it's a non-null object; our app config never sets it.
d.setdefault('search_syntaxes', {})

target = pathlib.Path('gui-src/gui/src/defaultApp.js')
with target.open('w') as f:
    f.write('export const defaultApp = ')
    json.dump(d, f, indent=2)
    f.write('\n')
print(f'Patched {target}')
PY

# TEMPORARY (paired with Patch 3 below): nomad-lab's entry overview page
# unconditionally shows every entry's root section in the "sections" card,
# with no config-level way to show it only for entries that actually need it
# (like our ELN metadata entries, which need it for their editable form and
# Synchronize button) while suppressing it for others (like our NMR
# simulation entries, where it just dumps raw internal fields). Gate it on
# the explicit overview=True ELN annotation instead - see Patch 3 for the
# corresponding schema-side flag.
RUN python3 <<'PY'
import pathlib

target = pathlib.Path('gui-src/gui/src/components/entry/OverviewView.js')

original = "        if (path === 'data' || sectionDef.m_annotations?.eln?.[0]?.overview) {\n"
patch = (
    "        // CCPNC: only explicitly-flagged sections render here (see\n"
    "        // CCPNCMetadataELN.m_def's overview=True annotation) - this used\n"
    "        // to unconditionally include every entry's root section too.\n"
    "        if (sectionDef.m_annotations?.eln?.[0]?.overview) {\n"
)

text = target.read_text()
count = text.count(original)
assert count == 1, (
    f"Expected exactly 1 occurrence of the target line in {target}, found {count}. "
    "nomad-lab's OverviewView.js has likely changed - update or drop this patch."
)
target.write_text(text.replace(original, patch, 1))
print(f"Patched {target}")
PY

# TEMPORARY: nomad-lab's EntryDownloadButton builds its download URL by
# interpolating JSON.stringify(query) directly into the URL with no
# encodeURIComponent. The browser auto-encodes characters that are outright
# invalid in a URL, but leaves "&" alone (it's a valid query-string
# delimiter) - so any query value containing a literal "&" (e.g. a chemical
# or author name) truncates json_query mid-string, and the backend's
# json.loads rejects it with "cannot parse json_query". Affects both the
# search results bulk-download button and the uploads processing table's
# per-entry download menu (both use this component).
# Remove this once nomad-lab ships a fix.
RUN python3 <<'PY'
import pathlib

target = pathlib.Path('gui-src/gui/src/components/entry/EntryDownloadButton.js')

original = "    const url = `${apiBase}/v1/entries/${urlSuffix}?owner=${owner}&json_query=${JSON.stringify(queryStringData)}`\n"
patch = "    const url = `${apiBase}/v1/entries/${urlSuffix}?owner=${encodeURIComponent(owner)}&json_query=${encodeURIComponent(JSON.stringify(queryStringData))}`\n"

text = target.read_text()
count = text.count(original)
assert count == 1, (
    f"Expected exactly 1 occurrence of the target line in {target}, found {count}. "
    "nomad-lab's EntryDownloadButton.js has likely changed - update or drop this patch."
)
target.write_text(text.replace(original, patch, 1))
print(f"Patched {target}")
PY

RUN cd gui-src/gui \
 && npm install -g yarn \
 && yarn install --frozen-lockfile \
 && NODE_OPTIONS=--openssl-legacy-provider CI=true REACT_APP_BACKEND_URL=/nomad-oasis yarn build

FROM builder AS docs

WORKDIR /app

ARG NOMAD_DOCS_REPO="https://github.com/FAIRmat-NFDI/nomad-docs.git"
ARG NOMAD_DOCS_REPO_REF="main"

RUN set -ex && \
    echo "Cloning from: ${NOMAD_DOCS_REPO}; branch: ${NOMAD_DOCS_REPO_REF}" && \
    git clone --branch "${NOMAD_DOCS_REPO_REF}" "${NOMAD_DOCS_REPO}" docs

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv run --with nomad-docs --directory docs mkdocs build \
    && mkdir -p built_docs \
    && cp -r docs/site/* built_docs

FROM builder AS gpu_action_builder

WORKDIR /app

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --extra plugins --extra gpu-action

FROM builder AS cpu_action_builder

WORKDIR /app

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --extra plugins --extra cpu-action

FROM base_final AS final

ARG PYTHON_VERSION=3.12

COPY --chown=nomad:${UID} --from=builder /opt/venv /opt/venv
COPY configs/nomad.yaml nomad.yaml
COPY pyproject.toml uv.lock /opt/
COPY --chown=nomad:${UID} --from=docs /app/built_docs /opt/venv/lib/python${PYTHON_VERSION}/site-packages/nomad/app/static/docs
COPY --chown=nomad:${UID} --from=gui_builder /app/gui-src/gui/build /opt/venv/lib/python${PYTHON_VERSION}/site-packages/nomad/app/static/gui

RUN mkdir -p /app/.volumes/fs \
 && chown -R nomad:${UID} /app \
 && chown -R nomad:${UID} /opt/venv \
 && mkdir nomad \
 && cp /opt/venv/lib/python${PYTHON_VERSION}/site-packages/nomad/jupyterhub_config.py nomad/

# fastapi 0.138+ added a _contains_router() assertion inside include_router(). optimade 1.2.4
# uses a plain starlette.routing.Router for its landing page (not a FastAPI APIRouter), so
# it lacks _contains_router and the assertion fails. Nomad's optimade/__init__.py already
# patches StarletteRouter for on_startup/on_shutdown; add _contains_router there too.
# Returning False is always correct: the landing Router never contains the app router.
RUN set -e \
 && sed -i \
    "s/setattr(StarletteRouter, 'on_shutdown', \[\])/&\nif not hasattr(StarletteRouter, '_contains_router'):\n    StarletteRouter._contains_router = lambda self, router, seen=None: False/" \
    "/opt/venv/lib/python${PYTHON_VERSION}/site-packages/nomad/app/optimade/__init__.py" \
 && grep -q "_contains_router" "/opt/venv/lib/python${PYTHON_VERSION}/site-packages/nomad/app/optimade/__init__.py"


USER nomad

# The application ports
EXPOSE 8000
EXPOSE 9000

VOLUME /app/.volumes/fs

FROM final AS cpu_action_final

COPY --chown=nomad:${UID} --from=cpu_action_builder /opt/venv /opt/venv

FROM final AS gpu_action_final

COPY --chown=nomad:${UID} --from=gpu_action_builder /opt/venv /opt/venv


FROM quay.io/jupyter/base-notebook:${JUPYTER_VERSION} AS jupyter_builder

ENV UV_PROJECT_ENVIRONMENT=/opt/conda \
    UV_FROZEN=1

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      gcc \
      build-essential \
      curl \
      zip \
      unzip \
      git \
      # clean cache and logs
      && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}
WORKDIR "${HOME}"

COPY --from=uv_image /uv /bin/uv

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    # Use inexact to avoid removing pre-installed packages in the environment
    # Use no-install-project to skip installing the current project (`nomad-distribution`)
    uv sync --extra plugins --extra jupyter --no-install-project --inexact


FROM quay.io/jupyter/base-notebook:${JUPYTER_VERSION} AS jupyter
# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      curl \
      zip \
      unzip \
      git \
      # `nbconvert` dependencies
      # https://nbconvert.readthedocs.io/en/latest/install.html#installing-tex
      texlive-xetex \
      texlive-fonts-recommended \
      texlive-plain-generic \
      # clean cache and logs
      && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}
WORKDIR "${HOME}"

COPY --from=uv_image /uv /bin/uv
COPY --from=jupyter_builder /opt/conda /opt/conda


# Get rid ot the following message when you open a terminal in jupyterlab:
# groups: cannot find name for group ID 11320
RUN touch ${HOME}/.hushlogin
