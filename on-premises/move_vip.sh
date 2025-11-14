#!/bin/bash

VIP="192.168.50.54"
INTERFACE="ens192"
LOGFILE="/var/log/keepalived-move-vip.log"
MYHOSTL=$(hostname -s)

# Função para registrar eventos
log_event() {
    echo "$(date): $1" >> $LOGFILE
}

# Função para adicionar o VIP
add_vip() {
    ip addr add $VIP/32 dev $INTERFACE
    log_event "VIP $VIP adicionado à interface $INTERFACE do host ${MYHOSTL}"
}

# Função para remover o VIP
remove_vip() {
    ip addr del $VIP/32 dev $INTERFACE
    log_event "VIP $VIP removido da interface $INTERFACE do host ${MYHOSTL}"
}

# Processa o estado recebido pelo Keepalived
case "$1" in
    "master")
        add_vip
        log_event "Máquina ${MYHOSTL} tornou-se MASTER"
        ;;
    "backup")
        remove_vip
        log_event "Máquina ${MYHOSTL} tornou-se BACKUP"
        ;;
    "fault")
        remove_vip
        log_event "Máquina ${MYHOSTL} entrou em estado FAULT"
        ;;
    *)
        log_event "Estado desconhecido: $1"
        ;;
esac