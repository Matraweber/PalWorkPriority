"""Install a checked Scripts zip on the dedicated server over FTP.

Run it yourself; it asks for the FTP login and never stores it:

    python tools/ftp_deploy_server.py <scripts.zip>             install
    python tools/ftp_deploy_server.py <scripts.zip> --dry-run   connect and check only
    python tools/ftp_deploy_server.py --rollback <backup name>  put a backup back

Install renames the live Scripts folder to Scripts-before-<tag> (the backup),
creates a fresh Scripts, uploads every .lua from the zip's Scripts/ folder, then
downloads each file back and compares SHA-256. Nothing is deleted. The server
must be restarted afterwards (panel Restart) to load the new code.

Host and port are in the GPortal panel under FTP access. --tls uses explicit
FTPS if the host requires it.
"""
import argparse
import datetime
import ftplib
import getpass
import hashlib
import io
import sys
import zipfile

MOD_DIR = "/Pal/Binaries/Win64/ue4ss/Mods/PalWorkPriority"


def connect(tls):
    host = input("FTP host (from the GPortal panel): ").strip()
    port = int(input("FTP port [21]: ").strip() or "21")
    user = input("FTP user: ").strip()
    password = getpass.getpass("FTP password (hidden): ")
    ftp = ftplib.FTP_TLS(timeout=20) if tls else ftplib.FTP(timeout=20)
    ftp.connect(host, port)
    ftp.login(user, password)
    if tls:
        ftp.prot_p()
    return ftp


def names(ftp, path):
    try:
        return {n.rsplit("/", 1)[-1] for n in ftp.nlst(path)}
    except ftplib.error_perm:
        return set()


def lua_files(zip_path):
    z = zipfile.ZipFile(zip_path)
    files = {}
    for name in z.namelist():
        if name.startswith("Scripts/") and name.endswith(".lua") and name.count("/") == 1:
            files[name.split("/", 1)[1]] = z.read(name)
    if "main.lua" not in files:
        sys.exit("zip has no Scripts/main.lua; nothing done")
    return files


def fetch(ftp, path):
    buf = io.BytesIO()
    ftp.retrbinary("RETR " + path, buf.write)
    return buf.getvalue()


def install(args):
    files = lua_files(args.zip)
    tag = args.tag or datetime.date.today().strftime("%Y%m%d")
    backup = "Scripts-before-" + tag
    print(f"{len(files)} Lua files from {args.zip}")
    ftp = connect(args.tls)
    present = names(ftp, MOD_DIR)
    if "Scripts" not in present:
        sys.exit(f"{MOD_DIR}/Scripts not found (saw {sorted(present)}); nothing done")
    if backup in present:
        sys.exit(f"{backup} already exists; pass --tag to pick another name. Nothing done")
    print(f"found {MOD_DIR}/Scripts with {len(names(ftp, MOD_DIR + '/Scripts'))} entries")
    if args.dry_run:
        print("dry run: connection and paths are fine, nothing changed")
        return
    ftp.rename(f"{MOD_DIR}/Scripts", f"{MOD_DIR}/{backup}")
    print(f"backup: Scripts -> {backup}")
    ftp.mkd(f"{MOD_DIR}/Scripts")
    for name, data in sorted(files.items()):
        ftp.storbinary(f"STOR {MOD_DIR}/Scripts/{name}", io.BytesIO(data))
    bad = []
    for name, data in sorted(files.items()):
        back = fetch(ftp, f"{MOD_DIR}/Scripts/{name}")
        if hashlib.sha256(back).digest() != hashlib.sha256(data).digest():
            bad.append(name)
    extra = {n for n in names(ftp, MOD_DIR + "/Scripts") if not n.startswith(".")} - set(files)
    ftp.quit()
    if bad or extra:
        print(f"VERIFY FAILED: mismatched {bad}, unexpected {sorted(extra)}")
        print(f"undo with: python tools/ftp_deploy_server.py --rollback {backup}")
        sys.exit(1)
    print(f"verified: all {len(files)} files read back identical")
    print("now press Restart in the GPortal panel to load the new code")


def rollback(args):
    ftp = connect(args.tls)
    present = names(ftp, MOD_DIR)
    if args.rollback not in present:
        sys.exit(f"{args.rollback} not found in {MOD_DIR}; nothing done")
    if "Scripts" in present:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        ftp.rename(f"{MOD_DIR}/Scripts", f"{MOD_DIR}/Scripts-failed-{stamp}")
        print(f"moved the current Scripts aside as Scripts-failed-{stamp}")
    ftp.rename(f"{MOD_DIR}/{args.rollback}", f"{MOD_DIR}/Scripts")
    ftp.quit()
    print(f"restored {args.rollback} as Scripts; restart the server")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("zip", nargs="?")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--tag", help="backup suffix, default today's date")
    p.add_argument("--rollback", metavar="BACKUP")
    p.add_argument("--tls", action="store_true")
    args = p.parse_args()
    if args.rollback:
        rollback(args)
    elif args.zip:
        install(args)
    else:
        p.error("give a zip to install or --rollback <backup>")


if __name__ == "__main__":
    main()
