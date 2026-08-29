#!/usr/bin/env bash
#
# This script is used to build RISC-V firmware, including ZSBL, OpenSBI, Kernel,
# u-root initrd, and package them into firmware.bin and firmware.img.
#
# Usage: ./build.sh {all|clean|firmware.bin|firmware.img|build_prerequisites|zsbl_build|opensbi_build|kernel_build|uroot_build|pack_tool_build|copy_firmware_files}
#
# Configuration can be overridden by environment variables, e.g., CHIP=sg2042 ./build.sh all

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration Variables ---
# CHIP variable: Defaults to sg2044. Can be overridden by setting the CHIP environment variable.
CHIP=${CHIP:-sg2044}
# FIRMWARE: Defines the boot flow. Supported values: 'linuxboot' (default) or 'edk2'
FIRMWARE=${FIRMWARE:-linuxboot}
# Output directory: Defaults to ./out
OUT=${PWD}/out

# Validate FIRMWARE variable
if [ "${FIRMWARE}" != "linuxboot" ] && [ "${FIRMWARE}" != "edk2" ]; then
    echo "Error: FIRMWARE must be set to either 'linuxboot' or 'edk2'. Current: ${FIRMWARE}"
    exit 1
fi

# Initialize PLAT as empty
PLAT=""

# Only assign PLAT logic if FIRMWARE is set to edk2
if [ "${FIRMWARE}" = "edk2" ]; then
    echo "--- Setting up EDK2 Platform Mapping ---"
    if [ "${CHIP}" = "sg2042" ]; then
        PLAT="SG2042-EVB"
    elif [ "${CHIP}" = "sg2044" ]; then
        PLAT="SD3-10"
    else
        echo "Error: Unsupported CHIP '${CHIP}' for EDK2 mode."
        exit 1
    fi
    echo "  Mapped PLAT: ${PLAT}"
fi

# Toolchain and Kernel Settings
CROSS_COMPILE=${CROSS_COMPILE:-riscv64-linux-gnu-} # Cross-compilation toolchain prefix
ARCH=${ARCH:-riscv}                                # Architecture
KERNEL_CONFIG=${KERNEL_CONFIG:-kexec_defconfig}    # Kernel configuration file


# Export variables so child processes (like nested 'make' calls) can use them
export CROSS_COMPILE
export ARCH

# --- Directory Definitions (relative to script location) ---
ZSBL_DIR=zsbl
OPENSBI_DIR=opensbi
OPENSBI_PLATFORM=generic
FIRMWARE_DIR=firmware
KERNEL_DIR=kernel_${CHIP} # Kernel directory depends on CHIP
UROOT_DIR=u-root
PACK_SRC_DIR=pack
CONFIGS_SRC_DIR=configs
EDK2_DIR=sophgo_edk2

# --- Output Image File Definitions ---
IMAGE_FILE=${PWD}/firmware.img
IMAGE_SIZE_MB=256 # Image size in MiB for dd
MOUNT_POINT=${PWD}/tmpmnt # Temporary mount point for image manipulation

# --- Functions ---

# Function to clean all generated files and intermediate build products
clean() {
    echo "--- Cleaning all generated files and intermediate build products ---"

    # Attempt to unmount any potentially mounted directories
    if mountpoint -q "${MOUNT_POINT}"; then
        echo "  Unmounting ${MOUNT_POINT}..."
        sudo umount "${MOUNT_POINT}" || true # Use '|| true' to prevent script exit if umount fails
    fi

    # Clean up kpartx mappings, prevent leftovers
    if [ -e "${IMAGE_FILE}" ]; then
        echo "  Removing kpartx mappings for ${IMAGE_FILE}..."
        sudo kpartx -d "${IMAGE_FILE}" || true # Use '|| true' as kpartx might fail if not mapped
    fi

    # Remove output directory and final image file
    echo "  Removing output directory '${OUT}' and image file '${IMAGE_FILE}'..."
    rm -rf "${OUT}" "${IMAGE_FILE}"

    # Clean individual component directories
    echo "  Cleaning ZSBL directory..."
    (cd "${ZSBL_DIR}" && make clean) || true
    echo "  Cleaning OpenSBI directory..."
    (cd "${OPENSBI_DIR}" && make clean) || true
    echo "  Cleaning Kernel directory..."
    (cd "${KERNEL_DIR}" && make clean) || true
    echo "  Cleaning u-root directory..."
    (cd "${UROOT_DIR}" && make clean) || true
    echo "  Cleaning pack tool directory..."
    (cd "${PACK_SRC_DIR}" && make clean) || true

    echo "--- Cleaning complete ---"
}

# Function to check Go compiler version
check_go_version() {
    echo "--- Checking Go compiler version ---"
    local GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    local MAJOR=$(echo "$GO_VERSION" | cut -d'.' -f1)
    local MINOR=$(echo "$GO_VERSION" | cut -d'.' -f2)
    local PATCH=$(echo "$GO_VERSION" | cut -d'.' -f3)

    if [ -z "$PATCH" ]; then
        PATCH=0
    fi

    echo "  Detected Go version: ${GO_VERSION}"
    if [ "$MAJOR" -gt 1 ] || ([ "$MAJOR" -eq 1 ] && [ "$MINOR" -ge 22 ]); then
        echo "Error: Go compiler version ${GO_VERSION} must be less than 1.22. Please downgrade your Go version."
        exit 1
    else
        echo "  Go compiler version check passed (less than 1.22)."
    fi
    echo "--- Go version check complete ---"
}

# Function to build ZSBL
zsbl_build() {
    echo "--- Building ZSBL (Mode: ${FIRMWARE}) ---"
    mkdir -p "${OUT}" || { echo "Error: Failed to create output directory ${OUT}."; exit 1; }
    echo "  Cleaning ZSBL in ${ZSBL_DIR}..."
    (cd "${ZSBL_DIR}" && make -j"$(nproc)" clean) || { echo "Error: ZSBL clean failed."; exit 1; }
    echo "  Configuring ZSBL with ${CHIP}_defconfig..."
    (cd "${ZSBL_DIR}" && make -j"$(nproc)" "${CHIP}_defconfig") || { echo "Error: ZSBL defconfig failed."; exit 1; }

    # Define extra options based on FIRMWARE type
    local ZSBL_OPTS=""
    if [ "${FIRMWARE}" = "linuxboot" ]; then
        ZSBL_OPTS="USE_LINUX_BOOT=1"
        echo "  Enabling USE_LINUX_BOOT macro for ZSBL..."
    fi

    echo "  Compiling ZSBL (zsbl.bin)..."
    (cd "${ZSBL_DIR}" && make -j"$(nproc)" zsbl.bin ${ZSBL_OPTS}) || { echo "Error: ZSBL compilation failed."; exit 1; }
    echo "  Copying zsbl.bin to ${OUT}/zsbl.bin..."
    cp -vf "${ZSBL_DIR}/zsbl.bin" "${OUT}/zsbl.bin" || { echo "Error: Failed to copy zsbl.bin."; exit 1; }
    echo "--- ZSBL build complete ---"
}

# Function to build OpenSBI
opensbi_build() {
    echo "--- Building OpenSBI ---"
    mkdir -p "${OUT}" || { echo "Error: Failed to create output directory ${OUT}."; exit 1; }
    echo "  Cleaning OpenSBI in ${OPENSBI_DIR}..."
    (cd "${OPENSBI_DIR}" && make -j"$(nproc)" clean) || { echo "Error: OpenSBI clean failed."; exit 1; }
    echo "  Compiling OpenSBI for platform ${OPENSBI_PLATFORM}..."
    (cd "${OPENSBI_DIR}" && make -j"$(nproc)" PLATFORM="${OPENSBI_PLATFORM}" FW_PIC=y BUILD_INFO=y) || { echo "Error: OpenSBI compilation failed."; exit 1; }
    echo "  Copying fw_dynamic.bin to ${OUT}/fw_dynamic.bin..."
    cp -vf "${OPENSBI_DIR}/build/platform/${OPENSBI_PLATFORM}/firmware/fw_dynamic.bin" "${OUT}/fw_dynamic.bin" || { echo "Error: Failed to copy fw_dynamic.bin."; exit 1; }
    echo "--- OpenSBI build complete ---"
}

# Function to build the Kernel and DTB files
kernel_build() {
    echo "--- Building Kernel and DTB files ---"
    mkdir -p "${OUT}" || { echo "Error: Failed to create output directory ${OUT}."; exit 1; }
    echo "  Configuring Kernel with ${KERNEL_CONFIG} in ${KERNEL_DIR}..."
    (cd "${KERNEL_DIR}" && make -j"$(nproc)" "${KERNEL_CONFIG}") || { echo "Error: Kernel defconfig failed."; exit 1; }
    if [ "${FIRMWARE}" = "linuxboot" ]; then
        echo "  [LinuxBoot Mode] Compiling full Kernel and DTBs..."
        (cd "${KERNEL_DIR}" && make -j"$(nproc)") || { echo "Error: Kernel compilation failed."; exit 1; }
        echo "  Copying Kernel Image to ${OUT}/riscv64_Image..."
        cp -vf "${KERNEL_DIR}/arch/riscv/boot/Image" "${OUT}/riscv64_Image" || { echo "Error: Failed to copy Kernel Image."; exit 1; }
    elif [ "${FIRMWARE}" = "edk2" ]; then
        echo "  [EDK2 Mode] Only compiling Device Tree Blobs (dtbs)..."
        (cd "${KERNEL_DIR}" && make -j"$(nproc)" dtbs) || { echo "Error: DTB compilation failed."; exit 1; }
    fi
    echo "  Copying DTB files to ${OUT}/..."
    # Keep the original logic for mango or chip-specific DTBs
    if find "${KERNEL_DIR}/arch/riscv/boot/dts/sophgo/" -maxdepth 1 -name "mango-*.dtb" -print -quit | grep -q .; then
        cp -vf "${KERNEL_DIR}/arch/riscv/boot/dts/sophgo/mango"-*.dtb "${OUT}/" || { echo "Error: Failed to copy mango DTB files."; exit 1; }
    else
        cp -vf "${KERNEL_DIR}/arch/riscv/boot/dts/sophgo/${CHIP}"-*.dtb "${OUT}/" || { echo "Error: Failed to copy ${CHIP} DTB files."; exit 1; }
    fi
    echo "--- Kernel build complete (Mode: ${FIRMWARE}) ---"
}

# Function to build u-root initrd
uroot_build() {
    echo "--- Building u-root initrd (Mode: ${FIRMWARE}) ---"
    if [ "${FIRMWARE}" = "linuxboot" ]; then
        check_go_version # Ensure Go version is compatible
        mkdir -p "${OUT}" || { echo "Error: Failed to create output directory ${OUT}."; exit 1; }
        echo "  Building u-root in ${UROOT_DIR}..."
        (cd "${UROOT_DIR}" && go build) || { echo "Error: u-root go build failed."; exit 1; }
        echo "  Creating initrd.img..."
        GOOS=linux GOARCH=riscv64 "${UROOT_DIR}/u-root" -uroot-source "${UROOT_DIR}" -build bb \
            -uinitcmd="boot" -o "${OUT}/initrd.img" \
            core boot || { echo "Error: u-root initrd creation failed."; exit 1; }
        echo "--- u-root initrd build complete ---"
    elif [ "${FIRMWARE}" = "edk2" ]; then
        echo "  [EDK2 Mode] Skipping u-root initrd build as it is not required."
    fi
}

# Function to copy firmware-specific files (fip.bin or fsbl.bin)
copy_firmware_files() {
    echo "--- Copying firmware-specific files ---"
    mkdir -p "${OUT}" || { echo "Error: Failed to create output directory ${OUT}."; exit 1; }
    if [ "${CHIP}" = "sg2042" ]; then
        echo "  Copying sg2042 fip.bin to ${OUT}/fip.bin..."
        cp -vf "${FIRMWARE_DIR}/${CHIP}/fip.bin" "${OUT}/fip.bin" || { echo "Error: Failed to copy fip.bin."; exit 1; }
    elif [ "${CHIP}" = "sg2044" ]; then
        echo "  Copying sg2044 fsbl.bin to ${OUT}/fsbl.bin..."
        cp -vf "${FIRMWARE_DIR}/${CHIP}/fsbl.bin" "${OUT}/fsbl.bin" || { echo "Error: Failed to copy fsbl.bin."; exit 1; }
    else
        echo "Error: Unknown CHIP type '${CHIP}'. Cannot copy firmware-specific files."
        exit 1
    fi
    echo "--- Firmware-specific files copied ---"
}

# Function to build the pack tool
pack_tool_build() {
    echo "--- Building pack tool ---"
    echo "  Building pack tool in ${PACK_SRC_DIR}..."
    (cd "${PACK_SRC_DIR}" && make) || { echo "Error: pack tool build failed."; exit 1; }
    echo "--- Pack tool build complete ---"
}

# Function to build EDK2 firmware
edk2_build() {
    echo "--- Building EDK2 Firmware (Mode: ${FIRMWARE}) ---"

    if [ "${FIRMWARE}" = "edk2" ]; then
        if [ ! -d "${EDK2_DIR}" ]; then
            echo "Error: EDK2 directory '${EDK2_DIR}' not found."
            exit 1
        fi

        (
            cd "${EDK2_DIR}" || exit 1
            export WORKSPACE=$(pwd)

            if [ "${CHIP}" = "sg2042" ]; then
                echo "  Configuring and Building for SG2042..."
                export GCC5_RISCV64_PREFIX=${CROSS_COMPILE}
                export PACKAGES_PATH=$WORKSPACE/edk2:$WORKSPACE/edk2-platforms:$WORKSPACE/edk2-non-osi
		source edk2/edksetup.sh || { echo "Error: edksetup.sh failed."; exit 1; }
		make -C edk2/BaseTools || { echo "Error: BaseTools build failed."; exit 1; }
                build -a RISCV64 -t GCC5 -b RELEASE -D ACPI_ENABLE=false \
                      -p Platform/Sophgo/SG2042Pkg/${PLAT}/${PLAT}.dsc || { echo "Error: SG2042 build failed."; exit 1; }
                cp -v "$WORKSPACE/Build/${PLAT}/RELEASE_GCC5/FV/${PLAT^^}.fd" "${OUT}/SG2042.fd" || { echo "Error: Failed to copy SG2042.fd."; exit 1; }
            elif [ "${CHIP}" = "sg2044" ]; then
                echo "  Configuring and Building for SG2044..."
                export GCC_RISCV64_PREFIX=${CROSS_COMPILE}
                export PACKAGES_PATH=$WORKSPACE/edk2:$WORKSPACE/edk2-platforms:$WORKSPACE/edk2-non-osi:$WORKSPACE/external-modules
                source edk2/edksetup.sh || { echo "Error: edksetup.sh failed."; exit 1; }
                make -C edk2/BaseTools || { echo "Error: BaseTools build failed."; exit 1; }
                build -a RISCV64 -t GCC -b RELEASE \
                      -p Platform/Sophgo/SG2044Pkg/${PLAT}/${PLAT}.dsc || { echo "Error: SG2044 build failed."; exit 1; }
                cp -v "$WORKSPACE/Build/${PLAT}/RELEASE_GCC/FV/${PLAT^^}.fd" "${OUT}/SG2044.fd" || { echo "Error: Failed to copy SG2044.fd."; exit 1; }
            fi
        ) || exit 1
        echo "--- EDK2 build complete ---"

    elif [ "${FIRMWARE}" = "linuxboot" ]; then
        echo "  [LinuxBoot Mode] Skipping EDK2 build."
    fi
}

# Function to ensure all build prerequisites are met
build_prerequisites() {
    echo "--- Running all build prerequisites (Mode: ${FIRMWARE}) ---"
    zsbl_build
    opensbi_build
    kernel_build
    uroot_build
    copy_firmware_files
    pack_tool_build
    edk2_build
    echo "--- All individual components built ---"

    echo "--- Preparing FIRM_OUT directory for image creation ---"
    mkdir -p "${OUT}/FIRM_OUT/riscv64" || { echo "Error: Failed to create FIRM_OUT directory."; exit 1; }
    echo "  Copying DTB files to ${OUT}/FIRM_OUT/riscv64/..."
    cp -vf "${OUT}"/*.dtb "${OUT}/FIRM_OUT/riscv64/" || { echo "Error: Failed to copy DTB files to FIRM_OUT."; exit 1; }

    # Conditional staging based on FIRMWARE mode
    if [ "${FIRMWARE}" = "linuxboot" ]; then
        echo "  [LinuxBoot Mode] Staging kernel and initrd..."
        echo "  Copying Kernel Image to ${OUT}/FIRM_OUT/riscv64/..."
        cp -vf "${OUT}/riscv64_Image" "${OUT}/FIRM_OUT/riscv64/" || { echo "Error: Failed to copy Kernel Image to FIRM_OUT."; exit 1; }
        echo "  Copying initrd.img to ${OUT}/FIRM_OUT/riscv64/..."
        cp -vf "${OUT}/initrd.img" "${OUT}/FIRM_OUT/riscv64/" || { echo "Error: Failed to copy initrd.img to FIRM_OUT."; exit 1; }
    elif [ "${FIRMWARE}" = "edk2" ]; then
        echo "  [EDK2 Mode] Skipping Kernel Image and initrd staging."
        local edk2_filename=""
        if [ "${CHIP}" = "sg2042" ]; then
            edk2_filename="SG2042"
        elif [ "${CHIP}" = "sg2044" ]; then
            edk2_filename="SG2044"
        fi
        echo "  Copying ${edk2_filename}.fd to ${OUT}/FIRM_OUT/riscv64/..."
        cp -vf "${OUT}/${edk2_filename}.fd" "${OUT}/FIRM_OUT/riscv64/" || { echo "Error: Failed to copy ${edk2_filename}.fd to FIRM_OUT."; exit 1; }
    fi
    echo "  Copying fw_dynamic.bin to ${OUT}/FIRM_OUT/riscv64/..."
    cp -vf "${OUT}/fw_dynamic.bin" "${OUT}/FIRM_OUT/riscv64/" || { echo "Error: Failed to copy fw_dynamic.bin to FIRM_OUT."; exit 1; }

    if [ "${CHIP}" = "sg2042" ]; then
        echo "  Copying sg2042 fip.bin to ${OUT}/FIRM_OUT/..."
        cp -vf "${OUT}/fip.bin" "${OUT}/FIRM_OUT/" || { echo "Error: Failed to copy fip.bin to FIRM_OUT."; exit 1; }
        echo "  Copying sg2042 zsbl.bin to ${OUT}/FIRM_OUT/..."
        cp -vf "${OUT}/zsbl.bin" "${OUT}/FIRM_OUT/" || { echo "Error: Failed to copy zsbl.bin to FIRM_OUT."; exit 1; }
    elif [ "${CHIP}" = "sg2044" ]; then
        echo "  Copying sg2044 fsbl.bin to ${OUT}/FIRM_OUT/riscv64/..."
        cp -vf "${OUT}/fsbl.bin" "${OUT}/FIRM_OUT/riscv64/" || { echo "Error: Failed to copy fsbl.bin to FIRM_OUT."; exit 1; }
        echo "  Copying sg2044 zsbl.bin to ${OUT}/FIRM_OUT/riscv64/..."
        cp -vf "${OUT}/zsbl.bin" "${OUT}/FIRM_OUT/riscv64/" || { echo "Error: Failed to copy zsbl.bin to FIRM_OUT."; exit 1; }
    fi
    echo "--- All build prerequisites and file staging complete ---"
}

# Function to package firmware.bin
firmware_bin() {
    build_prerequisites # Ensure all components are built and staged
    echo "--- Packaging firmware.bin for ${CHIP} chip (Mode: ${FIRMWARE}) ---"

    local DTBS_LOCAL=$(find "${OUT}" -maxdepth 1 -name "*.dtb")
    if [ -z "$DTBS_LOCAL" ]; then
        echo "Warning: No DTB files found in ${OUT} for packaging into firmware.bin."
    fi

    if [ "${CHIP}" = "sg2042" ]; then
        echo "  Processing sg2042 specific packaging steps..."
        "${PACK_SRC_DIR}/pack" -a -p fip.bin -t 0x600000 -f "${OUT}/fip.bin" -o 0x30000 firmware.bin || { echo "Error: pack fip.bin failed."; exit 1; }
        "${PACK_SRC_DIR}/pack" -a -p zsbl.bin -t 0x600000 -f "${OUT}/zsbl.bin" -l 0x40000000 firmware.bin || { echo "Error: pack zsbl.bin failed."; exit 1; }
        "${PACK_SRC_DIR}/pack" -a -p fw_dynamic.bin -t 0x600000 -f "${OUT}/fw_dynamic.bin" -l 0x0 firmware.bin || { echo "Error: pack fw_dynamic.bin failed."; exit 1; }
        # Conditionally pack kernel and initrd
        if [ "${FIRMWARE}" = "linuxboot" ]; then
            "${PACK_SRC_DIR}/pack" -a -p riscv64_Image -t 0x600000 -f "${OUT}/riscv64_Image" -l 0x2000000 firmware.bin || { echo "Error: pack riscv64_Image failed."; exit 1; }
            "${PACK_SRC_DIR}/pack" -a -p initrd.img -t 0x600000 -f "${OUT}/initrd.img" -l 0x30000000 firmware.bin || { echo "Error: pack initrd.img failed."; exit 1; }
        else
            "${PACK_SRC_DIR}/pack" -a -p SG2042.fd -t 0x600000 -f "${OUT}/SG2042.fd" -l 0x2000000 -o 0x2040000 firmware.bin || { echo "Error: pack SG2042.fd failed."; exit 1; }
        fi

        for dtb_file in ${DTBS_LOCAL}; do
            echo "  Adding $(basename "$dtb_file") to firmware.bin..."
            "${PACK_SRC_DIR}/pack" -a -p "$(basename "$dtb_file")" -t 0x600000 -f "$dtb_file" -l 0x20000000 firmware.bin || { echo "Error: pack $dtb_file failed."; exit 1; }
        done
    elif [ "${CHIP}" = "sg2044" ]; then
        echo "  Processing sg2044 specific packaging steps..."
        # Conditionally pack kernel and initrd
        if [ "${FIRMWARE}" = "linuxboot" ]; then
            "${PACK_SRC_DIR}/pack" -a -p riscv64_Image -t 0x80000 -f "${OUT}/riscv64_Image" -l 0x80200000 -o 0x600000 firmware.bin || { echo "Error: pack riscv64_Image failed."; exit 1; }
            "${PACK_SRC_DIR}/pack" -a -p initrd.img -t 0x80000 -f "${OUT}/initrd.img" -l 0x8b000000 firmware.bin || { echo "Error: pack initrd.img failed."; exit 1; }
        else
            "${PACK_SRC_DIR}/pack" -a -p SG2044.fd -t 0x80000 -f "${OUT}/SG2044.fd" -l 0x80200000 -o 0x600000 firmware.bin || { echo "Error: pack SG2044.fd failed."; exit 1; }
        fi
        "${PACK_SRC_DIR}/pack" -a -p fsbl.bin -t 0x80000 -f "${OUT}/fsbl.bin" -l 0x7010080000 firmware.bin || { echo "Error: pack fsbl.bin failed."; exit 1; }
        "${PACK_SRC_DIR}/pack" -a -p zsbl.bin -t 0x80000 -f "${OUT}/zsbl.bin" -l 0x40000000 firmware.bin || { echo "Error: pack zsbl.bin failed."; exit 1; }
        "${PACK_SRC_DIR}/pack" -a -p fw_dynamic.bin -t 0x80000 -f "${OUT}/fw_dynamic.bin" -l 0x80000000 firmware.bin || { echo "Error: pack fw_dynamic.bin failed."; exit 1; }
        for dtb_file in ${DTBS_LOCAL}; do
            echo "  Adding $(basename "$dtb_file") to firmware.bin..."
            "${PACK_SRC_DIR}/pack" -a -p "$(basename "$dtb_file")" -t 0x80000 -f "$dtb_file" -l 0x88000000 firmware.bin || { echo "Error: pack $dtb_file failed."; exit 1; }
        done
    else
        echo "Error: Unknown CHIP type '${CHIP}'. Please set to 'sg2042' or 'sg2044'."
        exit 1
    fi
    echo "--- firmware.bin packaging complete ---"
}

# Function to generate firmware.img
firmware_img() {
    build_prerequisites # Ensure all components are built and copied to FIRM_OUT
    echo "--- Starting disk image creation for ${IMAGE_FILE} ---"
    mkdir -p "${OUT}" || { echo "Error: Failed to create output directory ${OUT}."; exit 1; }

    echo "  Creating empty image file: ${IMAGE_FILE} with size ${IMAGE_SIZE_MB}MB..."
    dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count="${IMAGE_SIZE_MB}" status=none || { echo "Error: dd failed."; exit 1; }

    echo "  Partitioning image file with MBR and FAT32 partition..."
    sudo parted -s "${IMAGE_FILE}" mktable msdos || { echo "Error: parted mktable failed."; exit 1; }
    sudo parted -s "${IMAGE_FILE}" mkpart primary fat32 0% 100% || { echo "Error: parted mkpart failed."; exit 1; }

    echo "  Mapping image partitions to loop devices using kpartx..."
    # kpartx -av output format can vary, grep for the line that adds the map and extract the device name
    local loop_map_output
    loop_map_output=$(sudo kpartx -av "${IMAGE_FILE}" 2>&1 | grep 'add map')
    if [ -z "$loop_map_output" ]; then
        echo "Error: kpartx did not output a map line. Check kpartx installation and permissions."
        exit 1
    fi
    # Extract the device name, e.g., "loop0p1" from "add map loop0p1 (259:0): 0 524288 /dev/loop0 2048"
    local loop_part_name
    loop_part_name=$(echo "$loop_map_output" | awk '{print $3}')
    if [ -z "$loop_part_name" ]; then
        echo "Error: Failed to parse loop partition name from kpartx output."
        exit 1
    fi
    local mapped_dev="/dev/mapper/$loop_part_name"
    echo "  Mapped partition device: $mapped_dev"

    echo "  Formatting partition $mapped_dev as FAT32..."
    sudo mkfs.vfat "$mapped_dev" -n BOOTFIRM || { echo "Error: mkfs.vfat failed for $mapped_dev."; exit 1; }

    echo "  Creating mount point ${MOUNT_POINT} and mounting partition..."
    mkdir -p "${MOUNT_POINT}" || { echo "Error: mkdir ${MOUNT_POINT} failed."; exit 1; }
    sudo mount "$mapped_dev" "${MOUNT_POINT}" || { echo "Error: mount $mapped_dev to ${MOUNT_POINT} failed."; exit 1; }

    echo "  Copying firmware files from ${OUT}/FIRM_OUT/ to ${MOUNT_POINT}/..."
    # Ensure the source directory exists and contains files before copying
    sudo cp -vfR "${OUT}/FIRM_OUT/"* "${MOUNT_POINT}/" || { echo "Error: cp files to ${MOUNT_POINT} failed."; exit 1; }

    echo "  Unmounting partition and cleaning up loop devices..."
    sudo umount "${MOUNT_POINT}" || { echo "Error: umount ${MOUNT_POINT} failed."; exit 1; }
    rmdir "${MOUNT_POINT}" || true # rmdir might fail if not empty, so allow it
    sudo kpartx -d "${IMAGE_FILE}" || { echo "Error: kpartx -d failed."; exit 1; }
    echo "--- Disk image ${IMAGE_FILE} created and populated successfully ---"
}

# --- Main Execution Logic ---
# Parse command line arguments
case "$1" in
    clean)
        clean
        ;;
    firmware.bin)
        firmware_bin
        ;;
    firmware.img)
        firmware_img
        ;;
    zsbl_build)
        zsbl_build
        ;;
    opensbi_build)
        opensbi_build
        ;;
    kernel_build)
        kernel_build
        ;;
    uroot_build)
        uroot_build
        ;;
    pack_tool_build)
        pack_tool_build
        ;;
    copy_firmware_files)
        copy_firmware_files
        ;;
    edk2_build)
        edk2_build
        ;;
    build_prerequisites)
        build_prerequisites
        ;;
    all|"")
        firmware_bin
        firmware_img
        ;;
    *)
        echo "Usage: $0 {all|clean|firmware.bin|firmware.img|build_prerequisites|zsbl_build|opensbi_build|kernel_build|uroot_build|pack_tool_build|copy_firmware_files}"
        exit 1
        ;;
esac
