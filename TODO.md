# TODO
## Tier 0 Nodes
- [x] nvm-cli package installation
- [x] nfs-utils or nfs-common package installation for nfsiostat
- [ ] umount protection for the raid volumes and add details to the README document
- [x] numa node nvme match
- [ ] keep out the first and last NVMe drives from the raid
- [x] Block Device Read-Ahead
- [x] NFS client Read-Ahead
- [x] sunrpc module parameter pool_mode = pernode
- [x] use raid volumes without defining partitions
- [x] use /hammerspace directory as a root for all volume mount points
- [x] automatic or manualy tier 0 instance listing

## Hammerspace
- [ ] create AZ according to the rack distributions
- [ ] create nodes with:
  - [ ] --create-placement-objectives
- [ ] create volumes with:
  - [ ] --create-placement-objectives
  - [x] low-threshold 90, high-threshold 98
  - [ ] define optional --skip-configuration-test, --skip-performance-test
  - [ ] volume naming az${ser}:$hostname:$vol
  - [ ] optional additional-ip-add
  - [ ] optional availability_drop
- [ ] Tunable Anvil Delete Rate 
