set -e

echo
echo "${0} is starting..."


if ! command -v jq &> /dev/null
then
    echo
    echo "ERROR: The command 'jq' required by this script could not be found. 'jq' might"
    echo "       not be installed on your system. See https://jqlang.github.io/jq for details"
    echo "       regarding how to install 'jq'."
    exit 1
fi

echo
read -p "Enter ORCID client ID : " orcid_clientId
read -p "Enter ORCID client secret : " orcid_clientSecret
echo
read -p "Enter admin password for NOMAD Oasis and Keycloak : " adminpassword

echo
echo "INFO: Proceeding to insert client ID and client secret into 'configs/nomad-realm.json' file."
echo "      Before doing this a back-up of the file will be created called 'configs/nomad-realm.json.bak."
echo "      In case of errors, the changes to 'configs/nomad-realm.json' made by this script can be"
echo "      reverted by running the command: mv configs/nomad-realm.json.bak configs/nomad-realm.json"


if [ -f configs/nomad-realm.json.bak ]; then

    echo 
    echo "WARNING: Detected back-up file 'configs/nomad-realm.json.bak' created previously by this script."
    echo
    
    while true; do
        read -p "Do you wish to proceed and overwrite this file (Y/n)? " yn
        case $yn in
            [Yy]* )
		break
	        ;;
            [Nn]* )
		echo
		echo "${0} terminated without inserting secrets or changing admin password"
		exit
		;;
            * )
		echo "Please answer yes or no."
		;;
        esac
    done

fi


cp configs/nomad-realm.json configs/nomad-realm.json.bak

# WARNING: This assumes that the 'orcid' is the 1st element of the identityProvider
# array
jq ".identityProviders[0].config.clientId = \"$orcid_clientId\" | .identityProviders[0].config.clientSecret = \"$orcid_clientSecret\" " configs/nomad-realm.json.bak > configs/nomad-realm.json


echo
echo "INFO: Proceeding to change admin passwords in 'docker-compose.yaml' and 'configs/nomad.yaml'."
echo "      Before doing this a back-up of the files will be created called 'docker-compose.yaml.bak'"
echo "      and 'configs/nomad.yaml.bak. In case of errors, the changes to the two files made by this"
echo "      can be reverted by running the commands 'mv configs/nomad.yaml.bak configs/nomad.yaml'"
echo "      and 'mv docker-compose.yaml.bak docker-compose.yaml'."

if [ -f configs/nomad.yaml.bak ] || [ -f docker-compose.yaml.bak ]; then

    echo 
    echo "WARNING: Detected back-up file 'configs/nomad.yaml.bak' or 'docker-compose.yaml.bak' created previously by this script."
    echo
    
    while true; do
        read -p "Do you wish to proceed and overwrite this file (Y/n)? " yn
        case $yn in
            [Yy]* )
		break
	        ;;
            [Nn]* )
		echo
		echo "${0} terminated without changing admin password"
		exit
		;;
            * )
		echo "Please answer yes or no."
		;;
        esac
    done

fi

cp configs/nomad.yaml configs/nomad.yaml.bak
cp docker-compose.yaml docker-compose.yaml.bak

# Note that there are rigid assumptions about the format of the two yaml files here (e.g. whitespace between key and value)!
sed -i "s/password: 'password'/password: '$adminpassword'/" configs/nomad.yaml
sed -i "s/KEYCLOAK_PASSWORD=password/KEYCLOAK_PASSWORD=$adminpassword/" docker-compose.yaml

echo
echo "${0} has completed its job"