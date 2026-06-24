// pm2 ecosystem for the threeam downloader.
//
//   pm2 start ~/.threeam/ecosystem.config.js
//   pm2 logs threeam
//   pm2 save
//
// Why a file instead of `VAR=x pm2 start`: inline shell env vars are NOT
// reliably forwarded to the app by the pm2 daemon. The `env` block below is.
//
// Tune workers/tor live (no restart) by editing the control file:
//   echo '{"workers": 40, "tor": 6}' > ~/.threeam/download/.control.json
module.exports = {
  apps: [{
    name: "threeam",
    script: `${process.env.HOME}/.threeam/run.sh`,
    interpreter: "bash",
    autorestart: true,
    restart_delay: 60000,   // resume from .history.json after a crash/network drop
    max_restarts: 50,
    time: true,             // timestamp pm2 log lines
    env: {
      // The .onion (or http/local) listing. MUST end with ?sub=files.txt.
      LISTING_URL: "http://threeamkelxicjsaf2czjyz2lc4q3ngqkxhhlexyfcp2o6raw4rphyad.onion/detail/sn4jgn4a8h6tor8jcw4holx08szr1v?sub=files.txt",
      // Launch this many Tor instances. Pick a generous pool so you can raise
      // the live `tor` value up to it later without restarting.
      TOR_INSTANCES: "10",
      // Starting concurrency. Tune live via the control file.
      WORKERS: "20",
      // Upper bound for live worker tuning (thread-pool size).
      MAX_WORKERS: "200",
      // pm2 logs have no live panel; show only errors + checkpoint boxes.
      SHOW_FILES: "errors"
    }
  }]
};
