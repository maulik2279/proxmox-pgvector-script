# proxmox-pgvector-script

#Install new updates
apt  update

#Install Docker
apt install -y docker.io

#Run docker container for pgvector
docker run --name pgvector-container -e POSTGRES_USER=myuser -e POSTGRES_PASSWORD=mypassword -e POSTGRES_DB=mydatabase -p 5432:5432 -d ankane/pgvector

#Define cron jobs
cronjob1="@reboot docker start pgvector-container"


# Function to add cron jobs if they don't exist
add_cron_job() {
    local cronjob="$1"
    (crontab -l | grep -q "$cronjob") || (crontab -l 2>/dev/null; echo "$cronjob") | crontab -
}

# Add the defined cron jobs
add_cron_job "$cronjob1"

echo "Cron jobs added to run on reboot:"
echo "$cronjob1"

