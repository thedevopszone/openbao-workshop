FROM openbao/openbao-hsm-ubi:2.5.4
USER root

# SoftHSMv2-Library (PKCS#11) aus EPEL nachinstallieren
RUN microdnf install -y epel-release \
 && microdnf install -y softhsm \
 && microdnf clean all \
 # zeigt den exakten Library-Pfad – DIESEN Wert brauchst du in der seal-Stanza:
 && find / -name 'libsofthsm2.so*' 2>/dev/null

# Pod-Sicht auf den Token-Store: hier liegt er unter /softhsm/tokens
RUN mkdir -p /etc/softhsm \
 && printf 'directories.tokendir = /softhsm/tokens\nobjectstore.backend = file\nlog.level = INFO\n' \
      > /etc/softhsm/softhsm2.conf

USER openbao
