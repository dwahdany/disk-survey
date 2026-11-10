#!/usr/bin/env python3
"""Fill a folder with a made-up home folder for screenshots.

Every file is an APFS clone of one base file, truncated to the wanted length, so the tree
reports hundreds of gigabytes while occupying only the base file's blocks.

The names are invented; nothing is read from the machine it runs on.

    hdiutil create -type SPARSE -fs APFS -size 1t -volname Demo demo.sparseimage
    hdiutil attach demo.sparseimage -nobrowse
    Scripts/make-demo-tree.py /Volumes/Demo          # about 8 GB of real space, 823 GB apparent
    DiskSurvey --scan /Volumes/Demo/Users/alex --snapshot overview.png
    hdiutil detach /Volumes/Demo && rm demo.sparseimage

usage: make-demo-tree.py <folder on an APFS volume>
"""
import ctypes, os, random, sys, time

if len(sys.argv) != 2:
    sys.exit(__doc__)
root = sys.argv[1]
rng = random.Random(2026)
libc = ctypes.CDLL(None, use_errno=True)
BASE_SIZE = 8 << 30
base = os.path.join(root, ".base")
if not os.path.exists(base):
    chunk = os.urandom(1 << 20) * 64
    with open(base, "wb") as f:
        for _ in range(BASE_SIZE // len(chunk)):
            f.write(chunk)
now = time.time()
DAY = 86400
count = 0


def put(path, size, age_days):
    global count
    path = os.path.join(root, path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if libc.clonefile(base.encode(), path.encode(), 0) != 0:
        raise OSError(ctypes.get_errno(), path)
    os.truncate(path, max(1, int(min(size, BASE_SIZE))))
    t = now - age_days * DAY * rng.uniform(0.7, 1.3)
    os.utime(path, (t, t))
    count += 1


def lognorm(median, spread=0.6):
    return median * rng.lognormvariate(0, spread)


MB, GB, KB = 1 << 20, 1 << 30, 1 << 10
H = "Users/alex/"

# Movies
for trip, n, age in [("Iceland 2025", 14, 400), ("Wedding Film", 9, 900), ("Drone Footage", 22, 200),
                     ("Screen Recordings", 30, 60)]:
    for i in range(n):
        ext = "mov" if trip != "Screen Recordings" else "mp4"
        put(f"{H}Movies/{trip}/Clip {i + 1:03d}.{ext}", lognorm(2.4 * GB if ext == "mov" else 300 * MB, 0.7), age)
for name, n in [("Iceland Cut.fcpbundle", 60), ("Showreel.fcpbundle", 35)]:
    for i in range(n):
        put(f"{H}Movies/Final Cut/{name}/Render Files/High Quality Media/render-{i:04d}.mov", lognorm(450 * MB), 150)
    for i in range(200):
        put(f"{H}Movies/Final Cut/{name}/Original Media/thumb-{i:04d}.jpg", lognorm(180 * KB), 150)

# Pictures
for year in range(2019, 2027):
    for i in range(520 + 90 * (year - 2019)):
        r = rng.random()
        ext, med = ("heic", 2.6 * MB) if r < 0.72 else ("jpg", 4.5 * MB) if r < 0.86 else ("dng", 28 * MB) if r < 0.95 else ("mov", 140 * MB)
        put(f"{H}Pictures/Photos Library.photoslibrary/originals/{year}/{rng.randrange(16):X}/IMG_{year}{i:05d}.{ext}",
            lognorm(med, 0.5), (2026.8 - year) * 365)
for i in range(900):
    put(f"{H}Pictures/Photos Library.photoslibrary/resources/derivatives/{i % 16:X}/thumb_{i:05d}.jpg", lognorm(350 * KB), 300)
put(f"{H}Pictures/Photos Library.photoslibrary/database/Photos.sqlite", 1.3 * GB, 3)
for shoot, n in [("Studio Portraits", 240), ("Alps Hike", 180), ("Product Shots", 120)]:
    for i in range(n):
        put(f"{H}Pictures/Lightroom/{shoot}/DSC_{i:04d}.raf", lognorm(48 * MB, 0.25), 500)

# Music
artists = ["Northern Lanterns", "The Quiet Harbors", "Mara Velden", "Static Orchard", "Low Tide Radio",
           "Juniper & Vale", "Paper Satellites", "Oslo Night Bus", "Ferrous", "Calla Wren", "Hollow Pines",
           "Amber Circuit"]
albums = ["Live at the Mill", "First Light", "B-Sides", "Slow Weather", "Arrival", "Northbound", "Glasshouse"]
for a in artists:
    for al in rng.sample(albums, rng.randint(1, 4)):
        lossless = rng.random() < 0.3
        for t in range(rng.randint(8, 16)):
            put(f"{H}Music/Music/Media/{a}/{al}/{t + 1:02d} Track {t + 1}.{'flac' if lossless else 'm4a'}",
                lognorm(34 * MB if lossless else 9 * MB, 0.3), 1200)
for i in range(40):
    put(f"{H}Music/Logic/Album Demos.logicx/Media/Audio Files/Take {i + 1:02d}.wav", lognorm(210 * MB, 0.5), 250)
for lib in ["Orchestral Strings", "Vintage Keys", "Drum Kits"]:
    for i in range(60):
        put(f"{H}Music/Sample Libraries/{lib}/samples-{i:03d}.nki", lognorm(190 * MB, 0.6), 700)

# Developer
src_ext = [("ts", 6), ("tsx", 7), ("js", 5), ("json", 3), ("md", 4), ("css", 4), ("swift", 9), ("rs", 8), ("py", 6)]
for proj, kind in [("storefront-web", "node"), ("ledger-api", "rust"), ("fieldnotes-ios", "swift"),
                   ("ml-experiments", "python"), ("dotfiles", "plain"), ("render-engine", "rust")]:
    P = f"{H}Developer/{proj}/"
    for i in range(260):
        e, k = rng.choice(src_ext)
        put(f"{P}src/{rng.choice(['core', 'ui', 'api', 'util', 'models'])}/file{i:03d}.{e}", lognorm(k * KB), 40)
    for i in range(6):
        put(f"{P}.git/objects/pack/pack-{rng.getrandbits(64):016x}.pack", lognorm(220 * MB, 1.0), 30)
    if kind == "node":
        for pkg in range(420):
            for i in range(rng.randint(2, 9)):
                put(f"{P}node_modules/pkg-{pkg:03d}/dist/chunk-{i}.js", lognorm(260 * KB, 1.2), 90)
        for i in range(70):
            put(f"{P}.next/cache/webpack/{i:03d}.pack", lognorm(38 * MB), 10)
    if kind == "rust":
        for prof in ["debug", "release"]:
            for i in range(300):
                put(f"{P}target/{prof}/deps/lib{i:03d}.rlib", lognorm(14 * MB if prof == "debug" else 5 * MB, 0.9), 15)
            for i in range(40):
                put(f"{P}target/{prof}/incremental/unit-{i:02d}/dep-graph.bin", lognorm(60 * MB), 15)
    if kind == "swift":
        for i in range(220):
            put(f"{P}.build/arm64-apple-macosx/debug/Module{i:03d}.build/output.o", lognorm(3 * MB, 0.9), 12)
    if kind == "python":
        for i in range(12):
            put(f"{P}checkpoints/run-{i:02d}/model.safetensors", lognorm(3.2 * GB, 0.5), 80)
        for i in range(30):
            put(f"{P}data/shard-{i:03d}.parquet", lognorm(520 * MB, 0.4), 120)
        for i in range(500):
            put(f"{P}.venv/lib/python3.13/site-packages/pkg{i % 60:02d}/mod{i:03d}.so", lognorm(1.6 * MB, 1.1), 100)

# Library
L = H + "Library/"
for i in range(160):
    put(f"{L}Developer/Xcode/DerivedData/Fieldnotes-{rng.getrandbits(40):010x}/Build/Intermediates/unit{i:03d}.o", lognorm(40 * MB, 0.8), 20)
for dev in ["iPhone 17 Pro", "iPad Air", "Apple Watch"]:
    put(f"{L}Developer/CoreSimulator/Devices/{dev}/data.dmg", lognorm(6 * GB, 0.2), 45)
for os_ in ["iOS 26.1", "watchOS 26.1"]:
    put(f"{L}Developer/CoreSimulator/Volumes/{os_}.simruntime.dmg", 7.6 * GB, 60)
for app, med, n in [("com.example.browser", 30 * MB, 260), ("com.example.chat", 18 * MB, 200),
                    ("com.example.musicplayer", 55 * MB, 150), ("com.example.editor", 9 * MB, 240),
                    ("Homebrew", 70 * MB, 110), ("pip", 12 * MB, 140)]:
    for i in range(n):
        put(f"{L}Caches/{app}/{rng.getrandbits(32):08x}.cache", lognorm(med, 1.0), 25)
for app, n in [("Mail", 700), ("Messages", 500), ("Notes", 120)]:
    for i in range(n):
        put(f"{L}{app}/Data/{i % 20:02d}/item-{i:04d}.{'emlx' if app == 'Mail' else 'db'}", lognorm(1.8 * MB, 1.4), 600)
for i in range(90):
    put(f"{L}Application Support/Chat/Attachments/{i:03d}.mp4", lognorm(85 * MB, 0.9), 300)
for name in ["llama-3-8b-q4.gguf", "mistral-7b-q5.gguf", "phi-4-q8.gguf", "whisper-large.bin", "sdxl-base.safetensors"]:
    put(f"{L}Application Support/LocalModels/{name}", lognorm(5.5 * GB, 0.3), 100)
for c in ["com.example.notes", "com.example.photos-editor", "com.example.podcasts", "com.example.maps"]:
    for i in range(120):
        put(f"{L}Containers/{c}/Data/Library/Caches/blob-{i:03d}.dat", lognorm(22 * MB, 1.1), 200)

# Documents, Downloads, Desktop, VMs
for folder, n in [("Taxes", 60), ("Contracts", 40), ("Thesis", 180), ("Recipes", 90), ("Scans", 150)]:
    for i in range(n):
        e, med = rng.choice([("pdf", 2.4 * MB), ("docx", 400 * KB), ("key", 60 * MB), ("xlsx", 300 * KB), ("pages", 1.5 * MB)])
        put(f"{H}Documents/{folder}/{folder} {i + 1:03d}.{e}", lognorm(med, 0.9), 800)
for name, size in [("Xcode_26.1.xip", 3.1 * GB), ("ubuntu-26.04-desktop-arm64.iso", 5.4 * GB), ("Blender-4.5.dmg", 1.2 * GB),
                   ("dataset-archive.tar.gz", 7.2 * GB), ("fonts-collection.zip", 2.1 * GB), ("Installer.pkg", 900 * MB),
                   ("conference-talks.zip", 4.4 * GB)]:
    put(f"{H}Downloads/{name}", size, 180)
for i in range(140):
    e, med = rng.choice([("pdf", 3 * MB), ("zip", 60 * MB), ("dmg", 180 * MB), ("png", 2 * MB), ("mp4", 220 * MB)])
    put(f"{H}Downloads/download-{i:03d}.{e}", lognorm(med, 1.0), 240)
for vm in ["Ubuntu 26.04", "Windows 11 ARM"]:
    for i in range(6):
        put(f"{H}Virtual Machines/{vm}.utm/Data/disk-{i}.qcow2", lognorm(6.5 * GB, 0.15), 350)
for i in range(50):
    put(f"{H}Desktop/Screenshot 2026-{rng.randint(1, 10):02d}-{rng.randint(1, 28):02d} at {i:02d}.png", lognorm(3 * MB), 100)

print(count, "files")
