#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

temp="/tmp/ueot-install"
args="$*"

UEOT_HTTP_PORT="20080"
UEOT_VERSION="v1.3.0"

USERNAME="ueot"
HOME_DIR="/home/${USERNAME}"
COMPOSE_PROJECT_NAME="ueot"
UPDATE=false

export COMPOSE_PROJECT_NAME


while [[ $# -gt 0 ]]
do
key="$1"

case $key in
  --update)
    echo "Updating"
    UPDATE=true
    ;;

  *)
    # unknown option
    ;;
esac
shift # past argument key
done

install_docker() {
  if ! which docker > /dev/null 2>&1; then
    echo "Download and install Docker"
    curl -fsSL https://get.docker.com/ | sh
  fi

  DOCKER_VERSION=$(docker -v | sed 's/.*version \([0-9.]*\).*/\1/');
  DOCKER_VERSION_PARTS=( ${DOCKER_VERSION//./ } )
  echo "Docker version: ${DOCKER_VERSION}"

  if (( ${DOCKER_VERSION_PARTS[0]:-0} < 1
        || (${DOCKER_VERSION_PARTS[0]:-0} == 1 && ${DOCKER_VERSION_PARTS[1]:-0} < 12)
        || (${DOCKER_VERSION_PARTS[0]:-0} == 1 && ${DOCKER_VERSION_PARTS[1]:-0} == 12 && ${DOCKER_VERSION_PARTS[2]:-0} < 4) )); then
    echo "Docker version ${DOCKER_VERSION} is not supported. Please upgrade to version 1.12.4 or newer."
    exit 1;
  fi

  if ! which docker > /dev/null 2>&1; then
    echo >&2 "Docker not installed. Please check previous logs. Aborting."
    exit 1
  fi
}

install_docker_compose() {
  if ! which docker-compose > /dev/null 2>&1; then
    echo "Download and install Docker compose."
    curl -sL "https://github.com/docker/compose/releases/download/1.9.0/docker-compose-$(uname -s)-$(uname -m)" > /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi

  if ! which docker-compose > /dev/null 2>&1; then
    echo >&2 "Docker compose not installed. Please check previous logs. Aborting."
    exit 1
  fi

  DOCKER_COMPOSE_VERSION=$(docker-compose -v | sed 's/.*version \([0-9]*\.[0-9]*\).*/\1/');
  DOCKER_COMPOSE_MAJOR=${DOCKER_COMPOSE_VERSION%.*}
  DOCKER_COMPOSE_MINOR=${DOCKER_COMPOSE_VERSION#*.}
  echo "Docker Compose version: ${DOCKER_COMPOSE_VERSION}"

  if [ "${DOCKER_COMPOSE_MAJOR}" -lt 2 ] && [ "${DOCKER_COMPOSE_MINOR}" -lt 9 ] || [ "${DOCKER_COMPOSE_MAJOR}" -lt 1 ]; then
    echo >&2 "Docker compose version ${DOCKER_COMPOSE_VERSION} is not supported. Please upgrade to version 1.9 or newer."
    if [ "$UNATTENDED" = true ]; then exit 1; fi
    read -p "Would you like to upgrade Docker compose automatically? [y/N]" -n 1 -r
    echo
    if [[ ${REPLY} =~ ^[Yy]$ ]]
    then
      if ! curl -sL "https://github.com/docker/compose/releases/download/1.9.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose; then
        echo >&2 "Docker compose upgrade failed. Aborting."
        exit 1
      fi
      chmod +x /usr/local/bin/docker-compose
    else
      exit 1
    fi
  fi
}

create_user() {

  if [ -z "$(getent passwd ${USERNAME})" ]; then
    echo "Creating user ${USERNAME}."
    if ! useradd -m ${USERNAME}; then
      echo >&2 "Failed to create user '${USERNAME}'"
      exit 1
    fi

    if ! usermod -aG docker ${USERNAME}; then
      echo >&2 "Failed to add user '${USERNAME}' to docker group."
      exit 1
    fi
  fi
  chown "${USERNAME}" "${HOME_DIR}"
  export USER_ID=$(id -u "${USERNAME}")
}

change_owner() {
  # only necessary when installing for the first time, as root
  if [ "$EUID" -eq 0 ]; then
    cd "${HOME_DIR}"

    if ! chown -R "${USERNAME}" ./*; then
      echo >&2 "Failed to change config files owner"
      exit 1
    fi
  else
    echo "Not running as root - will not change config files owner"
  fi
}

write_metadata() {
  echo "version=${UEOT_VERSION}" | tee ${HOME_DIR}/metadata
}

create_docker_compose_file() {
  cd "${HOME_DIR}"

  if [ -f docker-compose.yml ]; then
    docker-compose down --remove-orphans
    {
      docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep 'ubnt/eot')
    } || {
      echo "WARNING: Failed to remove previous ubnt/eot image"
    }
    rm docker-compose.yml
  fi

cat << EOF > docker-compose.yml
version: '2'

services:
  postgres:
    container_name: ueot-postgres
    image: postgres:9.6.1-alpine
    restart: always
    volumes:
      - /home/ueot/postgres:/var/lib/postgresql/data/pgdata
    ports:
      - 6432:5432
    environment:
      - POSTGRES_DB=postgres
      - PGDATA=/var/lib/postgresql/data/pgdata

  redis:
    container_name: ueot-redis
    image: redis:alpine
    restart: always
    ports:
      - 6379:6379

  ueot:
    container_name: ueot
    image: ubnt/eot:1.3.0
    restart: always
    volumes:
      - /home/ueot/logs:/app/logs
    network_mode: host
    environment:
      - PLATFORM=linux
    depends_on:
      - postgres
      - redis

EOF
}

start_docker_containers() {
  echo "Starting docker containers."

  cd "${HOME_DIR}"

  if ! docker-compose up -d; then
    echo >&2 "Failed to start docker containers"
    exit 1
  fi
}

confirm_success() {
  echo "Waiting for UEOT to start"
  n=0
  until [ ${n} -ge 10 ]
  do
    sleep 3s
    ueotRunning=true
    nc -z 127.0.0.1 "${UEOT_HTTP_PORT}" && break
    echo "."
    ueotRunning=false
    n=$((n+1))
  done

  docker ps

  if [ "${ueotRunning}" = true ]; then
    echo "UEOT is running"
  else
    echo >&2 "UEOT is NOT running"
    exit 1
  fi
}

if [ "${UPDATE}" = false ]; then
  install_docker
  install_docker_compose
  create_user
fi

create_docker_compose_file
change_owner
start_docker_containers
write_metadata
confirm_success

exit 0
