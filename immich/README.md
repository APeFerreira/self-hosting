## Install the gcloud CLI

https://cloud.google.com/sdk/docs/install#deb

## Install FUSE

https://cloud.google.com/storage/docs/cloud-storage-fuse/install


echo user_allow_other | sudo tee -a /etc/fuse.conf   # one-time

sudo mkdir -m 700 /opt/gcp-creds
sudo mv gcp-creds/pi-hole-wireguard-vpn-69505c7a5a6c.json /opt/gcp-creds/
echo 'export GOOGLE_APPLICATION_CREDENTIALS=/opt/gcp-creds/pi-hole-wireguard-vpn-69505c7a5a6c.json' | sudo tee -a /etc/profile.d/gcp.sh
source /etc/profile.d/gcp.sh
sudo chmod 644 /etc/profile.d/gcp.sh

<!-- gcsfuse --file-mode 644 --dir-mode 755 immich-images /mnt/gcs/immich-images/
echo 'immich-images  /mnt/gcs/immich-images/  gcsfuse  rw,noatime,_netdev,implicit_dirs,key_file=/opt/gcp-creds/pi-hole-wireguard-vpn-69505c7a5a6c.json  0  0' | sudo tee -a /etc/fstab -->

sudo -i
gcsfuse --implicit-dirs -o allow_other --file-mode=666 --dir-mode=777 immich-images /mnt/gcs/immich-images
echo 'immich-images /mnt/gcs/immich-images gcsfuse rw,_netdev,implicit_dirs,allow_other,file_mode=666,dir_mode=777,key_file=/opt/gcp-creds/pi-hole-wireguard-vpn-69505c7a5a6c.json 0 0' | sudo tee -a /etc/fstab
exit

sudo journalctl -b | grep gcsfuse