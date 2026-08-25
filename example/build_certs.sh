# Generate Root CA
mkdir -p ca/root-ca/private ca/root-ca/db crl certs
chmod 700 ca/root-ca/private
cp /dev/null ca/root-ca/db/root-ca.db
cp /dev/null ca/root-ca/db/root-ca.db.attr
echo 01 > ca/root-ca/db/root-ca.crt.srl
echo 01 > ca/root-ca/db/root-ca.crl.srl

openssl req -new -config etc/root-ca.conf -newkey rsa:4096 -days 3650 -nodes -x509 -keyout ca/root-ca/private/root-ca.key -out ca/root-ca.crt -subj "/DC=org/DC=simple/O=Simple Inc/OU=Simple Root CA/CN=Simple Root CA" -extensions root_ca_ext

# Generate Signing CA
mkdir -p ca/signing-ca/private ca/signing-ca/db crl certs
chmod 700 ca/signing-ca/private
cp /dev/null ca/signing-ca/db/signing-ca.db
cp /dev/null ca/signing-ca/db/signing-ca.db.attr
echo 01 > ca/signing-ca/db/signing-ca.crt.srl
echo 01 > ca/signing-ca/db/signing-ca.crl.srl

openssl req -new -config etc/signing-ca.conf -newkey rsa:4096 -days 3650 -nodes -keyout ca/signing-ca/private/signing-ca.key -out ca/signing-ca.csr -subj "/DC=org/DC=simple/O=Simple Inc/OU=Simple Signing CA/CN=Simple Signing CA"
yes | openssl ca -config etc/root-ca.conf -in ca/signing-ca.csr -out ca/signing-ca.crt -extensions signing_ca_ext

# Generate server certificate
SAN=DNS:gitlab.simple.org openssl req -new -config etc/server.conf -out certs/gitlab.csr -keyout certs/gitlab.key -subj "/DC=org/DC=simple/O=Simple Inc/OU=Server/CN=gitlab.simple.org"
yes | openssl ca -config etc/signing-ca.conf -in certs/gitlab.csr -out certs/gitlab.crt -extensions server_ext

# Generate admin user
openssl req -new -nodes -sha512 -newkey rsa:4096 -keyout certs/flo.key -out certs/flo.csr -subj "/emailAddress=flolou@simple.org/CN=Flo Lou/O=Simple Inc/OU=Admins/C=FR/ST=State/L=City/DC=simple/DC=org"
yes | openssl ca -config etc/signing-ca.conf -in certs/flo.csr -out certs/flo.crt
openssl pkcs12 -inkey certs/flo.key -in certs/flo.crt -export -out certs/flo.pfx -passout pass:

# Generate simple user (with non-ascii characters)
openssl req -new -nodes -sha512 -newkey rsa:4096 -keyout certs/aze.key -out certs/aze.csr -subj "/emailAddress=azerty@simple.org/CN=Azé Rtÿiôµ/O=Simple Inc/OU=Users/C=FR/ST=State/L=City/DC=simple/DC=org"
openssl ca -config etc/signing-ca.conf -in certs/aze.csr -out certs/aze.crt
openssl pkcs12 -inkey certs/aze.key -in certs/aze.crt -export -out certs/aze.pfx -passout pass:
