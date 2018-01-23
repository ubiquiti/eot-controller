#!/bin/sh

which docker

if [ $? = 0 ]; then
  PATH="$PATH:/usr/local/bin"

  docker-compose stop
  docker-compose rm -f
  docker rmi --force $(docker images -a | grep "^ubnt/ueot" | awk '{print $3}')

  echo "Removed UniFi EoT docker containers and images."
else
  echo "Docker not installed, nothing to uninstall."
fi
