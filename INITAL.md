sudo apt install -y git parted dosfstools e2fsprogs grub-efi-amd64-bin xorriso rsync curl xz-utils
git clone https://github.com/YOUR_USERNAME/auto-k8s-loader.git
cd auto-k8s-loader
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL    # find your eSATA drive
sudo bash prepare-usb.sh /dev/sdX      # replace with eSATA device
