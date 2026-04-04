const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')
const Hyperswarm = require('hyperswarm')
const { execSync } = require('child_process')
const fs = require('fs')
const path = require('path')

const STORAGE_DIR = path.join(__dirname, '.update-server')

async function publish () {
  const store = new Corestore(STORAGE_DIR)
  const drive = new Hyperdrive(store)
  await drive.ready()

  console.log('Hyperdrive key:', drive.key.toString('hex'))
  console.log('Discovery key:', drive.discoveryKey.toString('hex'))

  // Build all platform bundles
  const presets = ['darwin', 'ios', 'android']
  for (const preset of presets) {
    const outFile = `worklet-${preset}.bundle`
    console.log(`Building ${outFile}...`)
    execSync(`npx bare-pack --preset ${preset} --linked --base . --out ./${outFile} ./worklet.js`, {
      cwd: __dirname,
      stdio: 'inherit'
    })

    const bundleData = fs.readFileSync(path.join(__dirname, outFile))
    await drive.put(`/bundles/${preset}/worklet.bundle`, bundleData)
    console.log(`Published ${preset}: ${bundleData.length} bytes`)
  }

  // Write version manifest
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8'))
  const manifest = {
    version: pkg.version,
    workletVersion: 'v36-pear-upgrade-20260317',
    timestamp: Date.now(),
    bundles: {
      darwin: '/bundles/darwin/worklet.bundle',
      ios: '/bundles/ios/worklet.bundle',
      android: '/bundles/android/worklet.bundle'
    }
  }
  await drive.put('/manifest.json', Buffer.from(JSON.stringify(manifest, null, 2)))
  console.log('Manifest written:', JSON.stringify(manifest))

  // Seed the drive so clients can find it
  const swarm = new Hyperswarm()
  swarm.on('connection', (conn) => store.replicate(conn))
  swarm.join(drive.discoveryKey)

  console.log('Seeding update drive...')
  console.log('Drive key (embed in native apps):', drive.key.toString('hex'))

  // Keep running to seed
  process.on('SIGINT', async () => {
    await swarm.destroy()
    await store.close()
    process.exit(0)
  })
}

publish().catch(err => {
  console.error('Publish failed:', err)
  process.exit(1)
})
