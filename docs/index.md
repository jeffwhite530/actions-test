# Slurm in Kubernetes

This project provides a containerized Slurm cluster solution running on Kubernetes.

## Features

- **Automatic Installation**: Automated deployment of Slurm's components and worker nodes (pods).
- **Database Integration**: Preconfigured MariaDB backend for job accounting and reporting.
- **Extensible**: Flexible deployment via Helm, with support for diverse storage configurations, including automatic provisioning of persistent volumes (PVs) or integration with pre-defined PVs.
- **Common Foundation**: Built with [Debian](https://hub.docker.com/_/debian), [MariaDB](https://mariadb.org/), and [Slurm](https://github.com/SchedMD/slurm).

## Components

These components are launched by the system as Kubernetes pods.

- **MariaDB**: Backend database for Slurm job accounting.
- **slurmdbd**: Handles Slurm's database communication.
- **slurmctld**: Slurm's central scheduler managing jobs and resources.
- **slurmd**: Compute node agent that executes jobs.
- **Slurm Node Watcher**: Syncs Kubernetes pods with Slurm nodes.

Additionally, a munge daemon is integrated into components to facilitate secure authentication with Slurm.

## Build Environment

- **HashiCorp Packer Templates**: For building optimized Slurm container images
- **Ansible Playbooks**: For automated system configuration and service deployment
- **Kubernetes Manifests**: For orchestrating the containerized Slurm environment
- **Helm Charts**: For packaging and simplified deployment
- **GitHub Action Templates**: For continuous integration/deployment pipelines

## Deploying

### Prerequisites

Ensure these tools are installed on your system:

- Ansible
- Docker
- HashiCorp Packer
- kubectl (configured for your Kubernetes cluster)
- Helm

### Build the Slurm container image

This will use Packer, Docker, and Ansible to build a docker image on your PC.

1. Edit `packer/build-slurm.pkr.hcl` and set variables.

    This must match a tag on <https://github.com/SchedMD/slurm/tags>.

    ```plaintext
    variable "slurm_version_tag" {
        default = "24-11-0-1"
    }
    ```

    Name your new image.

    ```plaintext
    variable "image_name" {
        default = "slurm"
        #default = "docker-registry.your.domain:5000/slurm"
    }
    ```

1. Use packer to build the image.

    ```shell
    cd packer

    packer init build-slurm.pkr.hcl

    packer build build-slurm.pkr.hcl
    ```

1. Update `helm/slurm-cluster/values.yaml` to set the image name, including registry and tag.

    It should be set in the default section:

    ```yaml
    defaults:
        image: docker-registry.your.domain:5000/slurm:24-11-0-1
    ```

    It can also be set individually on each component:

    ```yaml
    pods:
        slurmd:
            image: docker-registry.your.domain:5000/slurm:24-11-0-1-special
    ```

1. Finally, push this image to your Docker registry.

    ```shell
    docker push registry.your.domain:5000/slurm:24-11-0-1
    ```

### Set the MariaDB username and password

A password is needed by Slurm to communicate with the MariaDB instance that will be deployed.

#### Option 1: Automatic

Do not include a MariaDB password in your settings. One will be generated automatically and the user set to `root`. After deployment this password can be retrieved from Kubernetes:

```shell
kubectl get secret slurm-cluster-mariadb-root -o jsonpath="{.data.password}" | base64 -d ; echo
```

#### Option 2: secrets.yaml

Create `helm/secrets.yaml` and set your database username/pass.

```plaintext
mariadb:
    secret:
        username: "slurm"
        password: "your-actual-password-here"
```

#### Using an exising database

When the MariaDB pod has a persistentVolume mounted at /var/lib/mysql, that volume may contain an existing database (for example, a previous deployment of Slurm). In that case, the existing database's password must be set in the yaml file.

### Configure storage

1. Edit `helm/slurm-cluster/values.yaml` and set parameters for persistentVolumes. Three of them are required:

    ```yaml
    volumes:
        mariadb:
            - name: mariadb-data
            mountPath: /var/lib/mysql
        munge:
            - name: munge-etc
            mountPath: /etc/munge
        slurmctld:
            - name: slurmctld-spool
            mountPath: /var/spool/slurmctld
    ```

    More volumes can be added at any mountPath. For example, to mount a shared filesystem into the slurmd nodes:

    ```yaml
    # NFS example
    - name: home
        mountPath: /home
        # Optional, defaults to Retain
        reclaimPolicy: Delete
        size: 10Gi
        storageClassName: local-ssd
        accessModes:
            - ReadWriteMany
        spec:
            nfs:
                server: aster.your.domain
                path: /apps/slurm-cluster/slurmd/home
    ```

1. Ensure the storage specified in your values.yaml allows access by the UID also specified.

    ```yaml
    defaults:
        securityContext:
            runAsUser: 980
            runAsGroup: 980
            fsGroup: 980
    ```

    ```shell
    STORAGE_PATH=/apps/slurm-cluster

    mkdir -p "${STORAGE_PATH}/slurmctld/spool"
    mkdir -p "${STORAGE_PATH}/mariadb/data"
    mkdir -p "${STORAGE_PATH}/munge/etc"
    sudo chown -R 980:980 "${STORAGE_PATH}"
    ```

### Install the Helm chart

1. Set the namespace (or use `-n YOUR-NAMESPACE` in every command).

    ```shell
    export HELM_NAMESPACE=YOUR-NAMESPACE
    kubectl config set-context --current --namespace=YOUR-NAMESPACE
    ```

1. Edit `helm/slurm-cluster/values.yaml` with your preferences then validate the helm chart values. This should create valid Kubernetes YAML. If the validate step shows an error, review your values.yaml and try again.

    _Note: Add `-f secrets.yaml` if you have a secrets file._

    ```shell
    cd helm

    helm template slurm-cluster slurm-cluster/ -f secrets.yaml > rendered-manifests.yaml
    ```

1. Update helm dependencies.

    ```shell
    cd helm/slurm-cluster
    helm dependency update
    cd ../
    ```

1. Deploy the Kubernetes resources.

    ```shell
    kubectl create namespace YOUR-NAMESPACE
    ```

    _Note: Add `-f secrets.yaml` if you have a secrets file._

    ```shell
    helm install slurm-cluster slurm-cluster/ -f secrets.yaml
    ```

    The result should should be something like this:

    ```plaintext
    NAME: slurm-cluster
    LAST DEPLOYED: Sat Dec 28 15:51:42 2024
    NAMESPACE: YOUR-NAMESPACE
    STATUS: deployed
    REVISION: 1
    TEST SUITE: None
    NOTES:
    Thank you for installing slurm-cluster!

    Your Slurm cluster has been deployed with the following components:

    1. MariaDB database:
        Service: slurm-cluster-mariadb:3306

        To retrieve the MariaDB root password used during deployment, run:
            kubectl get secret -n YOUR-NAMESPACE slurm-cluster-mariadb-root -o jsonpath="{.data.password}" | base64 -d ; echo

    2. Slurm database daemon (slurmdbd):
        Service: slurm-cluster-slurmdbd:6819

    3. Slurm controller (slurmctld):
        Service: slurm-cluster-slurmctld:6817

    4. Slurm node watcher
        Monitors the Kubernetes event stream to add or remove slurmd nodes from the Slurm controller.

    5. Compute nodes (slurmd pods): 2

    To verify your installation:

    1. Check that all pods are running:
        kubectl get pods -n YOUR-NAMESPACE -l "app.kubernetes.io/instance=slurm-cluster"

    2. View component logs:
        kubectl logs -n YOUR-NAMESPACE -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=mariadb"
        kubectl logs -n YOUR-NAMESPACE -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmdbd"
        kubectl logs -n YOUR-NAMESPACE -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmctld"
        kubectl logs -n YOUR-NAMESPACE -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=node-watcher"
        kubectl logs -n YOUR-NAMESPACE -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmd"

    3. Check cluster status (from slurmctld pod):
        kubectl exec -n YOUR-NAMESPACE statefulset/slurm-cluster-slurmctld -- sinfo

    For more information about using Slurm, please refer to:
    https://slurm.schedmd.com/documentation.html
    ```

## Verification

1. Verify the helm release status.

    ```shell
    helm ls
    ```

    ```plaintext
    NAME                NAMESPACE         REVISION          UPDATED                                            STATUS             CHART                  APP VERSION
    slurm-cluster    slurm-cluster    2                    2024-12-22 14:23:07.923440676 -0500 EST deployed          slurm-cluster-0.1.024.11.0.1
    ```

1. Verify the resources launched.

    1. Did the pods start and are they ready?

        ```shell
        kubectl get pods -l "app.kubernetes.io/instance=slurm-cluster"
        ```

        ```plaintext
        NAME                                                        READY    STATUS     RESTARTS        AGE
        slurm-cluster-mariadb-0                              1/1      Running    0                 13m
        slurm-cluster-metrics-server-f44b5d76-wqw6l    1/1      Running    0                 13m
        slurm-cluster-node-watcher-0                        1/1      Running    0                 13m
        slurm-cluster-slurmctld-0                            1/1      Running    0                 13m
        slurm-cluster-slurmd-77f8554695-wjmgr            1/1      Running    0                 13m
        slurm-cluster-slurmdbd-0                             1/1      Running    0                 13m
        ```

    1. Did MariaDB launch successfully?

        ```shell
        kubectl logs -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=mariadb" --tail=-1
        ```

        ```plaintext
        2024-12-22 19:16:40+00:00 [Note] [Entrypoint]: Entrypoint script for MariaDB Server 11.6.2 started.
        2024-12-22 19:16:40+00:00 [Note] [Entrypoint]: MariaDB upgrade not required
        2024-12-22 19:16:40 0 [Note] Starting MariaDB 11.6.2-MariaDB source revision d8dad8c3b54cd09fefce7bc3b9749f427eed9709 server_uid ECAXpVBJpbtJNmAVANHBFmfORe4= as process 1
        2024-12-22 19:16:40 0 [Note] InnoDB: Compressed tables use zlib 1.2.11
        2024-12-22 19:16:40 0 [Note] InnoDB: Number of transaction pools: 1
        2024-12-22 19:16:40 0 [Note] InnoDB: Using crc32 + pclmulqdq instructions
        2024-12-22 19:16:40 0 [Note] mariadbd: O_TMPFILE is not supported on /tmp (disabling future attempts)
        2024-12-22 19:16:40 0 [Note] InnoDB: Using liburing
        2024-12-22 19:16:40 0 [Note] InnoDB: Initializing buffer pool, total size = 4.000GiB, chunk size = 64.000MiB
        2024-12-22 19:16:40 0 [Note] InnoDB: Completed initialization of buffer pool
        2024-12-22 19:16:40 0 [Note] InnoDB: File system buffers for log disabled (block size=512 bytes)
        2024-12-22 19:16:40 0 [Note] InnoDB: End of log at LSN=2547714
        2024-12-22 19:16:40 0 [Note] InnoDB: Opened 3 undo tablespaces
        2024-12-22 19:16:40 0 [Note] InnoDB: 128 rollback segments in 3 undo tablespaces are active.
        2024-12-22 19:16:40 0 [Note] InnoDB: Setting file './ibtmp1' size to 12.000MiB. Physically writing the file full; Please wait ...
        2024-12-22 19:16:40 0 [Note] InnoDB: File './ibtmp1' size is now 12.000MiB.
        2024-12-22 19:16:40 0 [Note] InnoDB: log sequence number 2547714; transaction id 5438
        2024-12-22 19:16:40 0 [Note] Plugin 'FEEDBACK' is disabled.
        2024-12-22 19:16:40 0 [Note] InnoDB: Loading buffer pool(s) from /var/lib/mysql/ib_buffer_pool
        2024-12-22 19:16:40 0 [Note] Plugin 'wsrep-provider' is disabled.
        2024-12-22 19:16:40 0 [Note] InnoDB: Buffer pool(s) load completed at 241222 19:16:40
        2024-12-22 19:16:41 0 [Note] Server socket created on IP: '0.0.0.0'.
        2024-12-22 19:16:41 0 [Note] Server socket created on IP: '::'.
        2024-12-22 19:16:41 0 [Note] mariadbd: Event Scheduler: Loaded 0 events
        2024-12-22 19:16:41 0 [Note] mariadbd: ready for connections.
        Version: '11.6.2-MariaDB'  socket: '/run/mariadb/mariadb.sock'  port: 3306  MariaDB Server
        ```

    1. Did slurmdbd launch successfully?

        ```shell
        kubectl logs -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmdbd" --tail=-1
        ```

        ```plaintext
        Defaulted container "slurmdbd" out of: slurmdbd, copy-slurmdbd-conf (init)
        2024-12-22T19:16:37.290Z Starting entrypoint script
        2024-12-22T19:16:37.291Z Preparing for munge daemon
        2024-12-22T19:16:37.301Z Checking for munge key
        2024-12-22T19:16:37.302Z Munge key already exists at /etc/munge/munge.key
        2024-12-22T19:16:37.304Z Starting munge daemon
        2024-12-22T19:16:38.307Z Preparing for slurmdbd daemon
        2024-12-22T19:16:38.313Z Waiting for mariadb to become available at slurm-cluster-mariadb-0
        2024-12-22T19:16:39.341Z Attempting to connect to slurm-cluster-mariadb-0:3306...
        2024-12-22T19:16:45.357Z Attempting to connect to slurm-cluster-mariadb-0:3306...
        2024-12-22T19:16:51.377Z Attempting to connect to slurm-cluster-mariadb-0:3306...
        2024-12-22T19:16:57.389Z Attempting to connect to slurm-cluster-mariadb-0:3306...
        2024-12-22T19:17:03.409Z Attempting to connect to slurm-cluster-mariadb-0:3306...
        2024-12-22T19:17:09.425Z Attempting to connect to slurm-cluster-mariadb-0:3306...
        2024-12-22T19:17:14.430Z mariadb is up at slurm-cluster-mariadb-0 - proceeding with startup
        2024-12-22T19:17:14.431Z Starting slurmdbd daemon
        slurmdbd: accounting_storage/as_mysql: _check_mysql_concat_is_sane: MySQL server version is: 11.6.2-MariaDB
        slurmdbd: accounting_storage/as_mysql: init: Accounting storage MYSQL plugin loaded
        slurmdbd: slurmdbd version 24.11.0 started
        ```

    1. Did slurmctld start successfully?

        ```shell
        kubectl logs -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmctld" --tail=-1
        ```

        ```plaintext
        2024-12-22T19:16:43.399Z Starting entrypoint script
        2024-12-22T19:16:43.400Z Preparing for munge daemon
        2024-12-22T19:16:43.410Z Checking for munge key
        2024-12-22T19:16:43.412Z Munge key already exists at /etc/munge/munge.key
        2024-12-22T19:16:43.413Z Starting munge daemon
        2024-12-22T19:16:44.416Z Preparing for slurmctld daemon
        2024-12-22T19:16:44.421Z Waiting for slurmdbd to become available at slurm-cluster-slurmdbd-0
        2024-12-22T19:16:45.453Z Attempting to connect to slurm-cluster-slurmdbd-0:6819...
        2024-12-22T19:16:51.469Z Attempting to connect to slurm-cluster-slurmdbd-0:6819...
        2024-12-22T19:17:26.555Z slurmdbd is up at slurm-cluster-slurmdbd-0 - proceeding with startup
        2024-12-22T19:17:26.556Z Starting slurmctld daemon
        slurmctld: slurmctld version 24.11.0 started on cluster slurm-cluster(2175)
        slurmctld: cred/munge: init: Munge credential signature plugin loaded
        slurmctld: select/linear: init: Linear node selection plugin loaded with argument 20
        slurmctld: select/cons_tres: init: select/cons_tres loaded
        slurmctld: accounting_storage/slurmdbd: init: Accounting storage SLURMDBD plugin loaded
        slurmctld: accounting_storage/slurmdbd: _load_dbd_state: recovered 0 pending RPCs
        slurmctld: accounting_storage/slurmdbd: clusteracct_storage_p_register_ctld: Registering slurmctld at port 6817 with slurmdbd
        slurmctld: _read_slurm_cgroup_conf: No cgroup.conf file (/etc/slurm/cgroup.conf), using defaults
        slurmctld: No memory enforcing mechanism configured.
        slurmctld: topology/default: init: topology Default plugin loaded
        slurmctld: sched: Backfill scheduler plugin loaded
        slurmctld: Recovered state of 1 nodes
        slurmctld: Recovered information about 0 jobs
        slurmctld: select/cons_tres: part_data_create_array: select/cons_tres: preparing for 1 partitions
        slurmctld: Recovered state of 0 reservations
        slurmctld: State of 0 triggers recovered
        slurmctld: read_slurm_conf: backup_controller not specified
        slurmctld: select/cons_tres: select_p_reconfigure: select/cons_tres: reconfigure
        slurmctld: select/cons_tres: part_data_create_array: select/cons_tres: preparing for 1 partitions
        slurmctld: Running as primary controller
        ```

    1. Did a slurmd instance start successfully?

        ```shell
        kubectl logs -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmd" --tail=-1
        ```

        ```plaintext
        2024-12-22T19:18:02.574Z Starting entrypoint script
        2024-12-22T19:18:02.575Z Preparing for munge daemon
        2024-12-22T19:18:02.585Z Checking for munge key
        2024-12-22T19:18:02.586Z Munge key already exists at /etc/munge/munge.key
        2024-12-22T19:18:02.588Z Starting munge daemon
        2024-12-22T19:18:03.591Z Preparing for slurmd daemon
        2024-12-22T19:18:03.596Z Waiting for slurmctld to become available at slurm-cluster-slurmctld-0
        2024-12-22T19:18:03.599Z slurmctld is up at slurm-cluster-slurmctld-0 - proceeding with startup
        2024-12-22T19:18:03.606Z Getting memory amount from cgroups v2
        4096
        2024-12-22T19:18:03.609Z Starting slurmd daemon
        slurmd: warning: Running with local config file despite slurmctld having been setup for configless operation
        slurmd: slurmd version 24.11.0 started
        slurmd: slurmd started on Sun, 22 Dec 2024 19:18:03 +0000
        slurmd: CPUs=1 Boards=1 Sockets=1 Cores=1 Threads=1 Memory=128717 TmpDisk=180686 Uptime=80365 CPUSpecList=(null) FeaturesAvail=(null) FeaturesActive=(null)
        ```

    1. Did the node watcher start successfully?

        ```shell
        kubectl logs -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=node-watcher" --tail=-1
        ```

        ```plaintext
        2024-12-22T19:16:34.778Z Starting entrypoint script
        2024-12-22T19:16:34.779Z Preparing for munge daemon
        2024-12-22T19:16:34.789Z Checking for munge key
        2024-12-22T19:16:34.790Z Munge key already exists at /etc/munge/munge.key
        2024-12-22T19:16:34.792Z Starting munge daemon
        2024-12-22T19:16:35.873Z Preparing for slurm-node-watcher daemon
        2024-12-22T19:16:35.876Z Waiting for slurmctld to become available at slurm-cluster-slurmctld-0
        2024-12-22T19:16:36.909Z Attempting to connect to slurm-cluster-slurmctld-0:6817...
        2024-12-22T19:16:42.925Z Attempting to connect to slurm-cluster-slurmctld-0:6817...
        2024-12-22T19:17:36.059Z slurmctld is up at slurm-cluster-slurmctld-0 - proceeding with startup
        2024-12-22T19:17:36.061Z Starting slurm-node-watcher daemon
        2024-12-22 19:17:37,483 - INFO - Starting Slurm node controller
        2024-12-22 19:17:37,484 - INFO - Performing initial sync...
        2024-12-22 19:17:37,598 - INFO - Removed node slurm-cluster-slurmd-77f8554695-p7s2h
        2024-12-22 19:17:37,598 - INFO - Initial sync complete
        2024-12-22 19:17:37,598 - INFO - Starting to watch for pod events...
        ```

## Launching a Test Job

This shows how to launch test jobs into Slurm after the cluster has deployed.

1. Check the Slurm cluster status.

    1. List the partitions.

        ```shell
        pod_name=$(kubectl get pods -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmctld" -o jsonpath='{.items[0].metadata.name}')

        kubectl exec -it $pod_name -- sinfo
        ```

        ```plaintext
        Defaulted container "slurmctld" out of: slurmctld, copy-slurmdbd-conf (init), copy-slurm-conf (init)
        PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
        main*          up    infinite        1    idle slurm-cluster-slurmd-77f8554695-wjmgr
        ```

    1. List the Slurm nodes.

        ```shell
        kubectl exec -it $pod_name -- scontrol show nodes
        ```

        ```plaintext
        Defaulted container "slurmctld" out of: slurmctld, copy-slurmdbd-conf (init), copy-slurm-conf (init)
        NodeName=slurm-cluster-slurmd-77f8554695-wjmgr Arch=x86_64 CoresPerSocket=1
            CPUAlloc=0 CPUEfctv=1 CPUTot=1 CPULoad=1.49
            AvailableFeatures=(null)
            ActiveFeatures=(null)
            Gres=(null)
            NodeAddr=10.10.1.231 NodeHostName=slurm-cluster-slurmd-77f8554695-wjmgr Version=24.11.0
            OS=Linux 6.1.0-28-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.119-1 (2024-11-22)
            RealMemory=4096 AllocMem=0 FreeMem=51734 Sockets=1 Boards=1
            State=IDLE+DYNAMIC_NORM ThreadsPerCore=1 TmpDisk=0 Weight=1 Owner=N/A MCS_label=N/A
            Partitions=main
            BootTime=2024-12-21T20:58:39 SlurmdStartTime=2024-12-22T19:18:03
            LastBusyTime=2024-12-22T19:17:37 ResumeAfterTime=None
            CfgTRES=cpu=1,mem=4G,billing=1
            AllocTRES=
            CurrentWatts=0 AveWatts=0
        ```

1. Launch a test hello-world Slurm job.

    1. Copy a job script into a container.

        ```shell
        pod_name=$(kubectl get pods -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmctld" -o jsonpath='{.items[0].metadata.name}')

        kubectl cp scripts/hello-world-job.sh "${pod_name}":/tmp/
        ```

    1. Submit the job.

        ```shell
        kubectl exec -it "${pod_name}" -- sbatch /tmp/hello-world-job.sh
        ```

        ```plaintext
        Defaulted container "slurmctld" out of: slurmctld, copy-slurmdbd-conf (init), copy-slurm-conf (init)
        Submitted batch job 1
        ```

    1. Check the job status.

        ```shell
        kubectl exec -it "${pod_name}" -- sacct --format=JobID,JobName,State,NodeList%25,StdOut,StdErr
        ```

        ```plaintext
        Defaulted container "slurmctld" out of: slurmctld, copy-slurmdbd-conf (init), copy-slurm-conf (init)
        JobID              JobName        State                        NodeList                    StdOut                    StdErr
        ------------ ---------- ---------- ------------------------- -------------------- --------------------
        1                 hello-wo+  COMPLETED slurm-cluster-slurmd-77f+        /tmp/job-%j.out        /tmp/job-%j.err
        1.batch              batch  COMPLETED slurm-cluster-slurmd-77f+
        ```

    1. Check the job's output file. Use the node (container name the job ran in) and log file from sacct above.

        ```shell
        pod_name=$(kubectl get pods -l "app.kubernetes.io/instance=slurm-cluster,app.kubernetes.io/component=slurmd" -o jsonpath='{.items[0].metadata.name}')

        kubectl exec -it "${pod_name}" -- cat /tmp/job-1.out
        ```

        ```plaintext
        Starting job at Sun Dec 22 23:31:33 UTC 2024
        Running on hostname: slurm-cluster-slurmd-77f8554695-wjmgr
        Job ID: 1
        Job name: hello-world
        Allocated nodes: slurm-cluster-slurmd-77f8554695-wjmgr
        Number of CPUs allocated: 1
        Job completed at Sun Dec 22 23:31:33 UTC 2024
        ```

## Adding and Removing slurmd Nodes

**Warning:** Reducing the replica count will delete slurmd pods in Kubernetes. This can result in the loss of active jobs on the affected nodes, as the Kubernetes scheduler is unaware of Slurm's job queue or state.

The slurmd deployment can be scaled manually using:

```shell
kubectl scale deployment/slurm-cluster-slurmd --replicas=N
```

The Slurm Node Watcher pod will automatically register new slurmd pods with Slurm when they appear and remove them from Slurm when a pod is deleted. However, it is recommended to edit `helm/slurm-cluster/values.yaml` to set the number of replicas then upgrade the chart:

```yaml
pods:
    slurmd:
        replicas: 2
```

_Note: Add `-f secrets.yaml` if you have a secrets file._

```shell
cd helm/

helm upgrade slurm-cluster slurm-cluster/
```

## Teardown

This will remove the cluster and its pods.

1. Delete the Kubernetes resources.

    ```shell
    helm uninstall slurm-cluster -n YOUR-NAMESPACE
    kubectl delete namespace YOUR-NAMESPACE
    ```

1. Clear shell configuration.

    ```shell
    kubectl config set-context --current --namespace=default

    unset HELM_NAMESPACE
    ```
