#
# Copyright contributors to the Hyperledgendary Full Stack Asset Transfer project
#
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
# 	  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Main justfile to run all the development scripts
# To install 'just' see https://github.com/casey/just#installation


###############################################################################
# COMMON TARGETS                                                              #
###############################################################################


# Ensure all properties are exported as shell env-vars
set export

# set the current directory, and the location of the test dats
CWDIR := justfile_directory()

_default:
  @just -f {{justfile()}} --list

check:
  ${CWDIR}/check.sh


###############################################################################
# MICROFAB / DEV TARGETS                                                      #
###############################################################################

# Shut down the microfab (uf) instance
microfab-bye:
    #!/bin/bash

    if docker inspect microfab &>/dev/null; then
        echo "Removing existing microfab container:"
        docker kill microfab
    fi


# Start a micro fab instance and create configuration in _cfg/uf
microfab: microfab-bye
    #!/bin/bash
    set -e -o pipefail

    export CFG=$CWDIR/_cfg/uf
    export MICROFAB_CONFIG='{
        "endorsing_organizations":[
            {
                "name": "org1"
            },
            {
                "name": "org2"
            }
        ],
        "channels":[
            {
                "name": "mychannel",
                "endorsing_organizations":[
                    "org1"
                ]
            },
            {
                "name": "appchannel",
                "endorsing_organizations":[
                    "org1","org2"
                ]
            }

        ],
        "capability_level":"V2_0"
    }'

    mkdir -p $CFG
    echo
    echo "Stating microfab...."

    docker run --name microfab -p 8080:8080 --add-host host.docker.internal:host-gateway --rm -d -e MICROFAB_CONFIG="${MICROFAB_CONFIG}"  ibmcom/ibp-microfab
    sleep 5

    curl -s http://console.127-0-0-1.nip.io:8080/ak/api/v1/components | weft microfab -w $CFG/_wallets -p $CFG/_gateways -m $CFG/_msp -f
    cat << EOF > $CFG/org1admin.env
    export CORE_PEER_LOCALMSPID=org1MSP
    export CORE_PEER_MSPCONFIGPATH=$CFG/_msp/org1/org1admin/msp
    export CORE_PEER_ADDRESS=org1peer-api.127-0-0-1.nip.io:8080
    export FABRIC_CFG_PATH=$CWDIR/config
    export CORE_PEER_CLIENT_CONNTIMEOUT=15s
    export CORE_PEER_DELIVERYTIMEOUT_CONNTIMEOUT=15s
    EOF

    cat << EOF > $CFG/org2admin.env
    export CORE_PEER_LOCALMSPID=org2MSP
    export CORE_PEER_MSPCONFIGPATH=$CFG/_msp/org2/org2admin/msp
    export CORE_PEER_ADDRESS=org2peer-api.127-0-0-1.nip.io:8080
    export FABRIC_CFG_PATH=$CWDIR/config
    export CORE_PEER_CLIENT_CONNTIMEOUT=15s
    export CORE_PEER_DELIVERYTIMEOUT_CONNTIMEOUT=15s
    EOF

    echo
    echo "To get an peer cli environment run:"
    echo
    echo 'source $WORKSHOP/_cfg/uf/org1admin.env'


debugcc:
    #!/bin/bash
    set -e -o pipefail

    export CFG=$CWDIR/_cfg/uf

    pushd $CWDIR/contracts/asset-transfer-typescript

    # this is the ip address the peer will use to talk to the CHAINCODE_ID
    # remember this is relative from where the peer is running.
    export CHAINCODE_SERVER_ADDRESS=host.docker.internal:9999
    export CHAINCODE_ID=$(weft chaincode package caas --path . --label asset-transfer --address ${CHAINCODE_SERVER_ADDRESS} --archive asset-transfer.tgz --quiet)
    export CORE_PEER_LOCALMSPID=org1MSP
    export CORE_PEER_MSPCONFIGPATH=$CFG/_msp/org1/org1admin/msp
    export CORE_PEER_ADDRESS=org1peer-api.127-0-0-1.nip.io:8080

    echo "CHAINCODE_ID=${CHAINCODE_ID}"

    set -x && peer lifecycle chaincode install asset-transfer.tgz &&     { set +x; } 2>/dev/null
    echo
    set -x && peer lifecycle chaincode approveformyorg --channelID mychannel --name asset-transfer -v 0 --package-id $CHAINCODE_ID --sequence 1 --connTimeout 15s && { set +x; } 2>/dev/null
    echo
    set -x && peer lifecycle chaincode commit --channelID mychannel --name asset-transfer -v 0 --sequence 1  --connTimeout 15s && { set +x; } 2>/dev/null
    echo
    set -x && peer lifecycle chaincode querycommitted --channelID=mychannel && { set +x; } 2>/dev/null
    echo
    popd

    cat << CC_EOF >> $CFG/org1admin.env
    export CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999
    export CHAINCODE_ID=${CHAINCODE_ID}
    CC_EOF

    echo "Added CHAINCODE_ID and CHAINCODE_SERVER_ADDRESS to org1admin.env"
    echo
    echo '   source $WORKSHOP/_cfg/uf/org1admin.env'


devshell:
    docker run \
        --rm \
        -u $(id -u) \
        -it \
        -v ${CWDIR}:/home/dev/workshop \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --network=host \
        fabgo:latest


###############################################################################
# CLOUD NATIVE TARGETS                                                        #
###############################################################################

cluster_name   := env_var_or_default("WORKSHOP_CLUSTER_NAME",   "kind")
namespace      := env_var_or_default("WORKSHOP_NAMESPACE",      "fabricinfra")
ingress_domain := env_var_or_default("WORKSHOP_DOMAIN",         "localho.st")


# Start a local KIND cluster with nginx, localhost:5000 registry, and *.localho.st alias in kube DNS
kind: unkind
    infrastructure/kind_with_nginx.sh {{cluster_name}}
    ls -lart ~/.kube/config
    chmod o+r ~/.kube/config

    echo "Kind cluster-info:"
    kubectl cluster-info


# Shut down the KIND cluster
unkind:
    #!/bin/bash
    kind delete cluster --name {{cluster_name}}

    if docker inspect kind-registry &>/dev/null; then
        echo "Stopping container registry"
        docker kill kind-registry
        docker rm kind-registry
    fi


###############################################################################
# ANSIBLE PLAYBOOK TARGETS                                                    #
###############################################################################

ANSIBLE_IMAGE := "ghcr.io/ibm-blockchain/ofs-ansibe:sha-65a953b"


# just set up everything with Ansible
ansible-doit: ansible-review-config operator console ansible-sample-network


# Review the Ansible Blockchain Collection configuration in _cfg/
ansible-review-config:
    #!/bin/bash
    mkdir -p _cfg
    rm -rf _cfg/*  || true

    cp ${CWDIR}/infrastructure/configuration/*.yml ${CWDIR}/_cfg

    echo ">> Fabric Operations Console Configuration"
    echo ""
    cat ${CWDIR}/_cfg/operator-console-vars.yml

    echo ">> Fabric Common Configuration"
    echo ""
    cat ${CWDIR}/_cfg/fabric-common-vars.yml

    echo ">> Fabric Org1 Configuration"
    echo ""
    cat ${CWDIR}/_cfg/fabric-org1-vars.yml

    echo ">> Fabric Org2 Configuration"
    echo ""
    cat ${CWDIR}/_cfg/fabric-org2-vars.yml

    echo ">> Fabric Orderer Configuration"
    echo ""
    cat ${CWDIR}/_cfg/fabric-ordering-org-vars.yml


# Start the Kubernetes fabric-operator with the Ansible Blockchain Collection
operator:
    #!/bin/bash
    set -ex -o pipefail

    docker run \
        --rm \
        -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
        -v ${CWDIR}/_cfg:/_cfg \
        -v $(pwd)/infrastructure/kind_console_ingress:/playbooks \
        --network=host \
        --workdir /playbooks \
        ${ANSIBLE_IMAGE} \
            ansible-playbook /playbooks/90-KIND-ingress.yml

    docker run \
        --rm \
        -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
        -v ${CWDIR}/_cfg:/_cfg \
        -v $(pwd)/infrastructure/operator_console_playbooks:/playbooks \
        --network=host \
        ${ANSIBLE_IMAGE} \
            ansible-playbook /playbooks/01-operator-install.yml


# Start the Fabric Operations Console with the Ansible Blockchain Collection
console:
    #!/bin/bash
    set -ex -o pipefail

    docker run \
        --rm \
        -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
        -v $(pwd)/infrastructure/operator_console_playbooks:/playbooks \
        -v ${CWDIR}/_cfg:/_cfg \
        --network=host \
        ${ANSIBLE_IMAGE} \
            ansible-playbook /playbooks/02-console-install.yml

    AUTH=$(curl -X POST https://{{namespace}}-hlf-console-console.{{ingress_domain}}:443/ak/api/v2/permissions/keys -u admin:password -k -H 'Content-Type: application/json' -d '{"roles": ["writer", "manager"],"description": "newkey"}')
    KEY=$(echo $AUTH | jq .api_key | tr -d '"')
    SECRET=$(echo $AUTH | jq .api_secret | tr -d '"')

    echo "Writing authentication file for Ansible based IBP (Software) network building"
    mkdir -p _cfg
    cat << EOF > $CWDIR/_cfg/auth-vars.yml
    api_key: $KEY
    api_endpoint: http://{{namespace}}-hlf-console-console.{{ingress_domain}}/
    api_authtype: basic
    api_secret: $SECRET
    EOF
    cat ${CWDIR}/_cfg/auth-vars.yml


# Build a sample Fabric network with the Ansible Blockchain Collection
ansible-sample-network:
    #!/bin/bash
    set -ex -o pipefail

    docker run \
        --rm \
        -u $(id -u) \
        -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
        -v ${CWDIR}/infrastructure/fabric_network_playbooks:/playbooks \
        -v ${CWDIR}/_cfg:/_cfg \
        --network=host \
        ${ANSIBLE_IMAGE} \
            ansible-playbook /playbooks/00-complete.yml


# Build a chaincode package with Ansible Blockchain Collection
ansible-build-chaincode:
    #!/bin/bash
    set -ex -o pipefail
    pushd ${CWDIR}/contracts/asset-transfer-typescript

    export IMAGE_NAME=localhost:5000/asset-transfer
    DOCKER_BUILDKIT=1 docker build -t ${IMAGE_NAME} . --target k8s
    docker push ${IMAGE_NAME}

    # note the double { } for escaping
    export IMG_SHA=$(docker inspect --format='{{{{index .RepoDigests 0}}' localhost:5000/asset-transfer | cut -d'@' -f2)
    weft chaincode package k8s --name ${IMAGE_NAME} --digest ${IMG_SHA} --label asset-transfer

    popd


# Deploy a chaincode package with the Ansible Blockchain Collection
ansible-deploy-chaincode:
    #!/bin/bash
    set -ex -o pipefail

    cp ${CWDIR}/contracts/asset-transfer-typescript/asset-transfer-chaincode-vars.yml ${CWDIR}/_cfg
    docker run \
        --rm \
        -u $(id -u) \
        -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
        -v ${CWDIR}/infrastructure/production_chaincode_playbooks:/playbooks \
        -v ${CWDIR}/_cfg:/_cfg \
        --network=host \
        ${ANSIBLE_IMAGE} \
            ansible-playbook /playbooks/19-install-and-approve-chaincode.yml

    docker run \
        --rm \
        -u $(id -u) \
        -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
        -v ${CWDIR}/infrastructure/production_chaincode_playbooks:/playbooks \
        -v ${CWDIR}/_cfg:/_cfg \
        --network=host \
        ${ANSIBLE_IMAGE} \
            ansible-playbook /playbooks/20-install-and-approve-chaincode.yml

    docker run \
        --rm \
        -u $(id -u) \
        -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
        -v ${CWDIR}/infrastructure/production_chaincode_playbooks:/playbooks \
        -v ${CWDIR}/_cfg:/_cfg \
        --network=host \
        ${ANSIBLE_IMAGE} \
            ansible-playbook /playbooks/21-commit-chaincode.yml


# register-application:
#     #!/bin/bash
#     set -ex -o pipefail

#     docker run \
#         --rm \
#         -u $(id -u) \
#         -v ${HOME}/.kube/:/home/ibp-user/.kube/ \
#         -v ${CWDIR}/infrastructure/fabric_network_playbooks:/playbooks \
#         -v ${CWDIR}/_cfg:/_cfg \
#         --network=host \
#         ${ANSIBLE_IMAGE}:latest \
#             ansible-playbook /playbooks/22-register-application.yml



