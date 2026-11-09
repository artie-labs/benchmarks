# Oracle bench box job queue

The bench box (m7i.2xlarge, 8 vCPU, 30 GB) and its RDS Oracle SE2 19c (db.m8i.xlarge) are in the customer-sandbox AWS
account, us-west-2. Use AWS profile customer-sandbox. Bucket: benchmark-oracle-3debc8cdf0814272bcfd41b84c.

- Never run benchmarks on the box directly. Submit a bash script: `/tmp/ob-scripts/submit-job.sh <name> <script>`.
  The box runs jobs one at a time, oldest first, in /opt/oracle-bench with $BUCKET set, after oracle-bench-sync.
- Output: s3://$BUCKET/results/queue/<timestamp>-<name>.log. Everything under /opt/oracle-bench/results/ syncs to
  s3://$BUCKET/results/ when a job ends. History (START/END with rc): s3://$BUCKET/results/queue/history.txt.
- Every job starts from an unknown table state: reseed and prime (`./bench.py setup --reset --seed-rows N`,
  `READER_IMAGE=... ./bench.py prime`). Deletes start at the middle of the seed and a 2M drain deletes 400k, a 4M drain 800k.
- Load your images inside the job: `aws s3 cp s3://$BUCKET/images/<file>.tar.gz - | gunzip | docker load`. Build images
  with /tmp/ss-tools/build-image.sh <commit> <tag> amd64 save (clean git archive, go1.27.3, CGO_ENABLED=0, GOAMD64=v1,
  -trimpath) and upload to s3://$BUCKET/images/.
- Template: /tmp/ob-scripts/job-goora.sh (5 rotating rounds, index file, a trace). bench.py's source is
  /Users/acorn/projects/js/artie/benchmarks/aws/oracle/box/bench.py (branch acorn/oracle-throughput). To change box files,
  upload them to s3://$BUCKET/box/<path> and they sync before your job.
- compose.yaml passes READER_GOGC and READER_GOMEMLIMIT to Reader (empty = Go defaults), TRANSFER_IMAGE to Transfer.
- Read-only looks on the box are fine: /tmp/ob-scripts/onbox.sh <instance id> <timeout> <cmd>, instance id from
  `terraform -chdir=/Users/acorn/projects/js/artie/benchmarks/aws/oracle/tf output -raw instance_id`.
- Benchmark rules: /Users/acorn/projects/js/artie/.agents/skills/code/benchmark.md (alternating pairs, medians, ranges,
  name the limiter). Don't create, change or destroy AWS resources; S3 objects under images/, box/, results/ only.

## Second box: the replay box (no database of its own)
- Instance `terraform -chdir=/Users/acorn/projects/js/artie/benchmarks/aws/oracle/tf output -raw replay_instance_id`
  (m7i.2xlarge, same setup, same IAM, same /opt/oracle-bench). It can reach RDS, but use it for work that doesn't need
  RDS: the demos LogMiner replay (`FROM=oracle_replay`), Oracle Free containers for integration tests, microbenchmarks.
- Submit with a third argument: `/tmp/ob-scripts/submit-job.sh <name> <script> queue-replay`. Output and history go to
  s3://$BUCKET/results/queue-replay/. Jobs run one at a time, oldest first, as on the main box.
- Don't run RDS benchmarks there while the main queue is running RDS jobs: they would share the database.
