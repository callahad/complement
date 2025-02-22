FROM golang:1.13-stretch as build
RUN apt-get update && apt-get install -y postgresql
WORKDIR /build

# pull files from branches
ARG BRANCH=master
ADD https://github.com/matrix-org/dendrite/archive/$BRANCH.tar.gz /build/dendrite.tar.gz

# strip the top-level directory which has the name of the branch in it
RUN tar --strip=1 -xzf dendrite.tar.gz
RUN go build ./cmd/dendrite-monolith-server
RUN go build ./cmd/generate-keys
RUN go build ./cmd/generate-config
RUN ./generate-config --ci > dendrite.yaml
RUN ./generate-keys --private-key matrix_key.pem --tls-cert server.crt --tls-key server.key

# Replace the connection string with a single postgres DB, using user/db = 'postgres' and no password
RUN sed -i "s%connection_string:.*$%connection_string: postgresql://postgres@localhost/postgres?sslmode=disable%g" dendrite.yaml 
# No password when connecting over localhost
RUN sed -i "s%127.0.0.1/32            md5%127.0.0.1/32            trust%g" /etc/postgresql/9.6/main/pg_hba.conf
# Bump up max conns for moar concurrency
RUN sed -i 's/max_connections = 100/max_connections = 2000/g' /etc/postgresql/9.6/main/postgresql.conf
RUN sed -i 's/max_open_conns:.*$/max_open_conns: 100/g' dendrite.yaml

# This entry script starts postgres, waits for it to be up then starts dendrite
RUN echo '\
#!/bin/bash -eu \n\
pg_lsclusters \n\
pg_ctlcluster 9.6 main start \n\
 \n\
until pg_isready \n\
do \n\
  echo "Waiting for postgres"; \n\
  sleep 1; \n\
done \n\
 \n\
sed -i "s/server_name: localhost/server_name: ${SERVER_NAME}/g" dendrite.yaml \n\
./dendrite-monolith-server --tls-cert server.crt --tls-key server.key --config dendrite.yaml \n\
' > run_dendrite.sh && chmod +x run_dendrite.sh

ENV SERVER_NAME=localhost
EXPOSE 8008 8448
CMD /build/run_dendrite.sh 
