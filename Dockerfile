# Worker/simulator image for the Acme support agent.
#
# Built with the PARENT directory as the Docker context (see Tiltfile /
# docker-compose.yml) so the sibling Continuous SDK at ../continuous/sdk/typescript
# resolves exactly as it does on the host — same dependency spec both ways. The
# Claude Code engine is bundled with @anthropic-ai/claude-agent-sdk, so the Node
# base image is all the runtime needed.
FROM node:22-slim

# Build the sibling SDK first: it has no prepare script and ships only dist/, so
# the sample's `npm install` needs the SDK's dist/ to already exist. Building it
# in-image keeps the result reproducible (not reliant on a host-built dist/).
COPY continuous/sdk/typescript     /continuous/sdk/typescript
RUN cd /continuous/sdk/typescript && npm install && npm run build

# Preserve the sibling layout so the `file:../continuous/sdk/typescript` dep
# resolves. (`npm install`, not --omit=dev: the worker runs via tsx, a devDep.)
COPY continuous-sample-typescript  /continuous-sample-typescript
WORKDIR /continuous-sample-typescript
RUN npm install

# Default to the worker; docker-compose overrides this for the simulator.
CMD ["npm", "run", "worker"]
