FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    parted dosfstools e2fsprogs mtools \
    grub-efi-amd64-bin grub-efi-amd64-signed shim-signed \
    xorriso rsync curl xz-utils \
    fdisk mount kmod \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY user-data user-data-pi meta-data k3s-config.env \
     first-boot.sh every-boot.sh pi-clone-to-nvme.sh \
     build-images.sh ./

RUN chmod +x build-images.sh

CMD ["./build-images.sh"]
