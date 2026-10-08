sudo mkdir -m 700 /opt/gcp-creds
sudo mv gcp-creds/key.json /opt/gcp-creds/
echo 'export GOOGLE_APPLICATION_CREDENTIALS=/opt/gcp-creds/key.json' | sudo tee -a /etc/profile.d/gcp.sh
source /etc/profile.d/gcp.sh
sudo chmod 644 /etc/profile.d/gcp.sh

gcsfuse --file-mode 644 --dir-mode 755 immich-images /mnt/gcs/immich-images/
on /etc/fstab append:
immich-images  /mnt/gcs/immich-images/  gcsfuse  rw,noatime,_netdev,implicit_dirs,key_file=/opt/gcp-creds/key.json  0  0