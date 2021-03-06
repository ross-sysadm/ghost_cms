#!/bin/bash
ENV_FILE=${1:-.env}
set -o allexport
source $ENV_FILE
set +o allexport

domains=($SERVER_NAME)
rsa_key_size=4096

#Check if docker and docker compose are installed , if not install it 
if ! [ -x "$(command -v docker-compose)" ] || ! [ "$(command -v docker)" ] ; then
  echo 'Error: Docker or docker-compose is not yet installed'
 if grep -iq "amzn" /etc/os-release ; then
     echo "Installing Docker and docker-compose on AWS EC2"
     sudo chmod +x docker-aws-linux-install.sh && ./docker-aws-linux-install.sh
 elif grep -iq "centos" /etc/os-release ; then
     echo "Installing Docker and docker-compose on RHEL or Centos"
     sudo chmod +x docker-centos-install.sh && ./docker-centos-install.sh
 else
     echo "Installing Docker and docker-compose on Ubuntu"
     sudo chmod +x docker-ubuntu-install.sh && ./docker-ubuntu-install.sh
 fi
fi
### Check for mysql and ghost home dir, if not found create it using the mkdir ##
[ ! -d "$MYSQL_DATA" ] && mkdir -p "$MYSQL_DATA"
[ ! -d "$GHOST_DATA" ] && mkdir -p "$GHOST_DATA"

if [ -d "$NGINX_CONFIG_PATH/letsencrypt" ]; then
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi
## set up certificate

if [ ! -e "$NGINX_CONFIG_PATH/letsencrypt/options-ssl-nginx.conf" ] || [ ! -e "$NGINX_CONFIG_PATH/letsencrypt/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$NGINX_CONFIG_PATH/letsencrypt"
#  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/tls_configs/options-ssl-nginx.conf > "$NGINX_CONFIG_PATH/letsencrypt/options-ssl-nginx.conf"
  cp ./configs/options-ssl-nginx.conf $NGINX_CONFIG_PATH/letsencrypt/options-ssl-nginx.conf
#  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/ssl-dhparams.pem > "$NGINX_CONFIG_PATH/letsencrypt/ssl-dhparams.pem"
  cp ./configs/dhparam.pem $NGINX_CONFIG_PATH/letsencrypt/dhparam.pem
  echo
fi

echo "### Creating dummy certificate for $domains ..."
path="/etc/letsencrypt/live/$domains"
mkdir -p "$NGINX_CONFIG_PATH/letsencrypt/live/$domains"
docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:1024 -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo


echo "### Starting nginx ..."
docker-compose up --force-recreate -d $NGINX_CONTAINER_NAME
echo

echo "### Deleting dummy certificate for $domains ..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo


echo "### Requesting Let's Encrypt certificate for $domains ..."
#Join $domains to -d args
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done
sed -e "s/SERVERNAME/$SERVER_NAME/g" $PWD/$NGINX_CONFIG_PATH/*.conf

# Select appropriate email arg
case "$EMAIL" in
  "") email_arg="--register-unsafely-without-email" ;;
#  *) email_arg="--email $EMAIL" ;;
esac

# Enable staging mode if needed
if [ $STAGING != "0" ]; then staging_arg="--staging"; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot
echo

echo "### Reloading nginx ..."
docker-compose exec $NGINX_CONTAINER_NAME $NGINX_CONTAINER_NAME -s reload
