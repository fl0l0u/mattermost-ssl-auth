# Example
## Pre-requisite
* `openssl` installed

## Create testing certificates
```bash
bash build_certs.sh
```

## Installation
* Use `certs/*.pfx` to install user certificates
* (optional) Install `ca/root-ca.crt` as root CA
* (optional) Install `ca/signing-ca.crt` as intermediate root CA
* Copy server certificates:
```bash
cp certs/gitlab.{crt,key} /etc/ssl/private/
cat ca/*.crt > /etc/ssl/private/ca.crt
```
* (optional) configure gitlab alias (`gitlab.simple.org`) in /etc/hosts
* Follow main project installation steps to configure a Gitlab with SSL authentication

## Connection
Open browser and connect to https://gitlab.simple.org or directly using the IP address of your test server