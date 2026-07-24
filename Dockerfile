# The parent build context must contain these sibling directories:
# continuous/ and continuous-sample-typescript/.
FROM node:22-slim

COPY continuous/sdk/typescript /continuous/sdk/typescript
RUN npm install --global pnpm@11.12.0 \
    && cd /continuous/sdk/typescript \
    && pnpm install --frozen-lockfile

COPY continuous-sample-typescript /continuous-sample-typescript
WORKDIR /continuous-sample-typescript
RUN npm ci && npm run check:sdk

CMD ["npm", "run", "worker"]
