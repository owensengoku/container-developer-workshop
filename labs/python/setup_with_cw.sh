export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
export REGION=us-central1

export USE_GKE_GCLOUD_AUTH_PLUGIN=True

export IMAGE=gcr.io/$PROJECT_ID/codeoss-python:latest
export CONFIG=codeoss-python-config.json
export NAME=codeoss-python
export WS_CLUSTER=my-cluster

gcloud services enable \
    cloudresourcemanager.googleapis.com \
    container.googleapis.com \
    sourcerepo.googleapis.com \
    containerregistry.googleapis.com \
    spanner.googleapis.com \
    workstations.googleapis.com

# create cloud workstation cluster config file
mkdir cw
cat << EOF > cw/cluster.json
{
"network": "projects/$PROJECT_ID/global/networks/default",
"subnetwork": "projects/$PROJECT_ID/regions/$REGION/subnetworks/default",
}
EOF

# create cloud workstation cluster using config
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
 -H "Content-Type: application/json" \
 -d @cw/cluster.json \
"https://workstations.googleapis.com/v1beta/projects/$PROJECT_ID/locations/$REGION/workstationClusters?workstation_cluster_id=${WS_CLUSTER}"

## GKE CLUSTER

gcloud container clusters create python-cluster \
--zone us-central1-a \
--num-nodes 1 \
--machine-type e2-standard-8 \
--workload-pool ${PROJECT_ID}.svc.id.goog --async


#Dockerfile for custom cloud workstation image
cat <<EOF > cw/Dockerfile
FROM us-central1-docker.pkg.dev/cloud-workstations-images/predefined/code-oss:latest
RUN sudo apt update
RUN sudo apt install -y gettext-base jq httpie
#Python Debugger extension
RUN wget https://open-vsx.org/api/ms-python/python/2022.18.2/file/ms-python.python-2022.18.2.vsix && \
unzip ms-python.python-2022.18.2.vsix "extension/*" &&\
mv extension /opt/code-oss/extensions/python-debugger
EOF



#build custom image
gcloud auth configure-docker
docker build cw -t $IMAGE

#push image to gcr
docker push $IMAGE

echo "Checking GKE clustering readiness"
while [ $(gcloud container clusters list --filter="name=python-cluster" --format="value(status)") == "PROVISIONING" ]
do
  echo "Waiting for GKE cluster to be ready"
  sleep 15s
done
gcloud container clusters get-credentials python-cluster --zone us-central1-a 

export KSA_NAME=python-ksa
export NAMESPACE=default
kubectl create serviceaccount ${KSA_NAME} \
    --namespace ${NAMESPACE}


export GSA_NAME=python-gsa
gcloud iam service-accounts create ${GSA_NAME} \
    --project=${PROJECT_ID}

# set IAM Roles
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member "serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/spanner.databaseAdmin"    
gcloud iam service-accounts add-iam-policy-binding ${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]"


kubectl annotate serviceaccount ${KSA_NAME} \
    --namespace ${NAMESPACE} \
    iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com


# check if workstation cluster has finished creating
export RECONCILING="true"
export RECONCILING=$(curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        -H "Content-Type: application/json" \
        "https://workstations.googleapis.com/v1beta/projects/$PROJECT_ID/locations/$REGION/workstationClusters/${WS_CLUSTER}" | jq -r '.reconciling')
echo "Is Cloud Workstation still RECONCILING? : $RECONCILING"
while [ $RECONCILING == "true" ]
    do
        sleep 1m
        export RECONCILING=$(curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        -H "Content-Type: application/json" \
        "https://workstations.googleapis.com/v1beta/projects/$PROJECT_ID/locations/$REGION/workstationClusters/${WS_CLUSTER}" | jq -r '.reconciling')
        echo "Is Cloud Workstation still RECONCILING? : $RECONCILING"
    done

rm -rf cw
