#!/usr/bin/env bash

ZSBL_COMMIT_ID=a717a31153a18dfc8f0ceae02daa0c70e5ae7770
ZSBL_BRANCH=sg204x
ZSBL_GIT=https://github.com/revyos/zsbl.git
ZSBL_DIR=zsbl

OPENSBI_COMMIT_ID=13abda516928a8823e6b7b65b0a29bb338484227
OPENSBI_BRANCH=master
OPENSBI_GIT=https://github.com/riscv-software-src/opensbi.git
OPENSBI_DIR=opensbi

SG2042_COMMIT_ID=b795aa4e6c086ae8f9e9446388b67dfb56b9e0f4
SG2042_BRANCH=sg2042-upstream-v6.15.y
SG2042_GIT=https://github.com/revyos/sg2042-vendor-kernel.git
SG2042_CONFIG=kexec_defconfig
SG2042_DIR=kernel_sg2042

SG2044_COMMIT_ID=7602a1bf63860cb36f45cf65beeea3be9b4e52ab
SG2044_BRANCH=sg2044-upstream-v6.15.y
SG2044_GIT=https://github.com/revyos/sg2044-vendor-kernel.git
SG2044_CONFIG=kexec_defconfig
SG2044_DIR=kernel_sg2044

git clone --single-branch -b ${ZSBL_BRANCH} ${ZSBL_GIT} ${ZSBL_DIR}
git -C ${ZSBL_DIR} checkout ${ZSBL_COMMIT_ID}

git clone --single-branch -b ${OPENSBI_BRANCH} ${OPENSBI_GIT} ${OPENSBI_DIR}
git -C ${OPENSBI_DIR} checkout ${OPENSBI_COMMIT_ID}

git clone --depth=1 -b ${SG2042_BRANCH} ${SG2042_GIT} ${SG2042_DIR}
#git -C ${SG2042_DIR} checkout ${SG2042_COMMIT_ID}

git clone --depth=1 -b ${SG2044_BRANCH} ${SG2044_GIT} ${SG2044_DIR}
#git -C ${SG2044_DIR} checkout ${SG2044_COMMIT_ID}
