# OpenFn Lightning — Air-Gapped Deployment Package

An air-gapped deployment pkg for openFn

## Repo map

```
.
├── RUNBOOK.md              # ministry admin
├── DECISIONS.md            # trade offs and thought process
├── README.md               
├── bundle/
│   ├── build-bundle.sh     # runs on jump host
│   ├── compose/
│   │   └── docker-compose.yml
│   ├── env/
│   │   └── .env.template       # documented. no screts
│   ├── server-scripts/         # index scripts for the admin
│   │   ├── 00-verify-bundle.sh
│   │   ├── 01-load-images.sh
│   │   ├── 02-generate-secrets.sh
│   │   ├── 03-start.sh
│   │   ├── 04-create-admin.sh
│   │   ├── 05-verify.sh
│   │   ├── status.sh
│   │   ├── healthcheck.sh
│   │   └── backup-db.sh
│   └── systemd/
│       ├── openfn-healthcheck.service
│       └── openfn-healthcheck.timer
└── dist/                   # Build output (this is gitignored)
```


