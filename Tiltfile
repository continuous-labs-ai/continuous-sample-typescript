# Setup 2 — the agent as a production-like container (preview/production regime).
#
# The build context spans this repo AND the sibling ../continuous so the SDK
# resolves; `only` keeps the context tight. `git_sha` pins the worker's queue to a
# deploy SHA — defaults to HEAD, so `tilt up` on the PR branch lands the worker on
# queue sha:<pr_head_sha>. Override with: tilt up -- --git_sha=<sha>
config.define_string('git_sha')
cfg = config.parse()
git_sha = cfg.get('git_sha', str(local('git rev-parse HEAD', quiet=True)).strip())
os.putenv('CONTINUOUS_GIT_SHA', git_sha)
print('continuous-sample-typescript: worker pinned to CONTINUOUS_GIT_SHA=%s' % git_sha)

docker_build(
    'continuous-sample-typescript-worker',
    context='..',
    dockerfile='Dockerfile',
    only=['continuous/sdk/typescript', 'continuous-sample-typescript'],
    ignore=[
        '**/node_modules', '**/dist', '**/build', '**/*.tsbuildinfo',
        'continuous/.git', '**/.env',
    ],
)

docker_compose('docker-compose.yml')
dc_resource('worker', labels=['agent'])
dc_resource('simulate', labels=['agent'], auto_init=False)  # traffic for replay/shadow/monitor; trigger manually
