"""Regression tests for Mac/Linux host initialization, requiring no running DB."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('configure_db', ROOT / 'ops/configure-db.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

class RuntimeTests(unittest.TestCase):
    def test_san_checks_do_not_accept_cn_or_wrong_hosts(self):
        text = 'X509v3 Subject Alternative Name:\n    DNS:localhost, DNS:*.example.com, IP Address:172.20.0.2, IP Address:0:0:0:0:0:0:0:1\n'
        for host in ('localhost','one.example.com','172.20.0.2','::1'):
            self.assertTrue(config.certificate_san_matches(text, host), host)
        for host in ('example.com','two.one.example.com','172.20.0.3','localhost.attacker.com'):
            self.assertFalse(config.certificate_san_matches(text, host), host)
        self.assertFalse(config.certificate_san_matches('CN=localhost', 'localhost'))

    def test_dev_tls_runs_on_system_bash_and_openssl(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'generate-dev-tls.sh'
            shutil.copyfile(ROOT / 'redis/generate-dev-tls.sh', script)
            result = subprocess.run(['/bin/bash', str(script)], env={**os.environ, 'PATH': '/usr/bin:/bin'}, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace')[-1000:])
            cert = Path(directory) / 'tls/server/server.crt'
            text = subprocess.check_output(['/usr/bin/openssl','x509','-in',str(cert),'-text','-noout']).decode()
            self.assertTrue(config.certificate_san_matches(text, '172.20.0.2'))
            self.assertEqual((Path(directory)/'tls/server/server.key').stat().st_mode & 0o777, 0o600)

    def test_elasticsearch_dev_tls_preserves_existing_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            script=Path(directory)/'generate-dev-tls.sh'
            shutil.copyfile(ROOT/'elasticsearch/generate-dev-tls.sh',script)
            env={**os.environ,'PATH':'/usr/bin:/bin'}
            first=subprocess.run(['/bin/bash',str(script)],env=env,capture_output=True)
            self.assertEqual(first.returncode,0,first.stderr.decode(errors='replace')[-500:])
            key=Path(directory)/'certs/http.key';before=key.read_bytes()
            second=subprocess.run(['/bin/bash',str(script)],env=env,capture_output=True)
            self.assertNotEqual(second.returncode,0)
            self.assertEqual(key.read_bytes(),before)
            text=subprocess.check_output(['/usr/bin/openssl','x509','-in',str(Path(directory)/'certs/http.crt'),'-text','-noout']).decode()
            self.assertTrue(config.certificate_san_matches(text,'agora-elasticsearch'))
            self.assertTrue(config.certificate_san_matches(text,'127.0.0.1'))

    def test_tls_volume_copies_only_leaf_material_without_changing_host_key(self):
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/'source';target=Path(directory)/'target'
            source.mkdir();target.mkdir()
            for name in ('http.crt','http.key','ca.crt','ca.key'):(source/name).write_text('synthetic-'+name)
            (source/'http.key').chmod(0o600)
            owner=(source/'http.key').stat().st_uid
            script=(ROOT/'elasticsearch/prepare-tls-volume.sh').read_text().replace('/source/',str(source)+'/').replace('/target',str(target))
            script='chown() { :; }\n'+script
            result=subprocess.run(['/bin/bash','-c',script],env={**os.environ,'ES_HTTP_TLS_ENABLED':'true'},capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            self.assertEqual((source/'http.key').stat().st_uid,owner)
            self.assertEqual((source/'http.key').stat().st_mode & 0o777,0o600)
            self.assertEqual((target/'http.key').stat().st_mode & 0o777,0o600)
            self.assertFalse((target/'ca.key').exists())
            self.assertEqual((target/'ca.crt').read_text(),'synthetic-ca.crt')
            (source/'ca.crt').unlink()
            (source/'ca.crt').symlink_to(source/'http.crt')
            result=subprocess.run(['/bin/bash','-c',script],env={**os.environ,'ES_HTTP_TLS_ENABLED':'true'},capture_output=True)
            self.assertNotEqual(result.returncode,0)

    def test_generated_paths_with_spaces_and_quotes_survive_shell_and_parser(self):
        with tempfile.TemporaryDirectory(prefix="agora path ") as directory:
            path=Path(directory)/'.env';path.write_text('PATH_SETTING=old\n');path.chmod(0o600)
            value=directory+"/owner's certs/ca.crt"
            config.update_env_file(path,{'PATH_SETTING':value})
            self.assertEqual(config.read_env(path)['PATH_SETTING'],value)
            result=subprocess.run(['/bin/bash','-c','source "$1"; printf "%s" "$PATH_SETTING"','bash',str(path)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,value)

    def test_primary_argument_forwarding_on_system_bash(self):
        source = (ROOT/'redis/init-redis.sh').read_text()
        function = source[source.index('run_on_local_primary() {'):source.index('\nuse_local_docker() {')]
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory)/'redis-container-cli.sh'
            cli.write_text('''#!/bin/bash
set -eu
mode="$2";shift 2
if [ "$mode" = admin ];then printf 'role:master\\r\\n';else printf '<%s>\\n' "$@";fi
''');cli.chmod(0o700)
            script = '''set -euo pipefail
SCRIPT_DIR="$TEST_DIR"
docker() {
 if [[ "$*" == *State.Running* ]];then
  if [ "${@: -1}" = "$SELECTED" ];then echo true;else echo false;fi
 else printf 'REDIS_NODE_BIND_IP=172.20.0.9\\nREDIS_NODE_PORT=6380\\n';fi
}
'''+function+'\nrun_on_local_primary app "argument with spaces"\n'
            cases=[('agora-redis-primary','<argument with spaces>\n'),('agora-redis-node','<-h>\n<172.20.0.9>\n<-p>\n<6380>\n<argument with spaces>\n')]
            for name,expected in cases:
                result=subprocess.run(['/bin/bash','-c',script], env={**os.environ,'TEST_DIR':directory,'SELECTED':name}, capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout,expected)

if __name__=='__main__':unittest.main()
