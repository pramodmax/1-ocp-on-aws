apiVersion: v1
baseDomain: ${base_domain}
featureSet: Default

controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: ${master_instance_type}
      rootVolume:
        size: ${master_root_volume_size}
        type: ${root_volume_type}
      zones: ${jsonencode(availability_zones)}
  replicas: ${master_count}

compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      type: ${worker_instance_type}
      rootVolume:
        size: ${worker_root_volume_size}
        type: ${root_volume_type}
      zones: ${jsonencode(availability_zones)}
  replicas: ${worker_count}

metadata:
  name: ${cluster_name}

networking:
  clusterNetwork:
  - cidr: ${cluster_network_cidr}
    hostPrefix: ${cluster_network_host_prefix}
  machineNetwork:
  - cidr: ${machine_network_cidr}
  networkType: ${network_type}
  serviceNetwork:
  - ${service_network_cidr}

platform:
  aws:
    region: ${aws_region}

fips: ${fips_enabled}
publish: ${publish}
pullSecret: '${pull_secret}'
sshKey: '${ssh_public_key}'
