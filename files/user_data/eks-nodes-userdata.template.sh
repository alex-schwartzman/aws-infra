#!/bin/bash
sed -i '/^KUBELET_EXTRA_ARGS=/a KUBELET_EXTRA_ARGS+=" --register-with-taints=${taints}"' /etc/eks/bootstrap.sh
