# A throwaway Alpine machine that boots OpenRC as PID 1 (busybox init), for the apk's install + start-at-boot test.
# It boots with nothing of Nostr Vault on it; the test installs the apk, sets it up, restarts the container (a reboot)
# and checks the vault and the mesh came back by themselves. Test tools only (ss): the apk brings its own depends.
ARG ALPINE=3.22
FROM alpine:${ALPINE}
RUN apk add --no-cache openrc iproute2-ss \
 && sed -i 's/^#\{0,1\}rc_sys=.*/rc_sys="docker"/' /etc/rc.conf \
 && sed -i '/getty/d' /etc/inittab
CMD ["/sbin/init"]
