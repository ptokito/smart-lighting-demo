# -----------------------------------------------------------------------------
# lighting-portal container image (Node.js + New Relic Node agent)
# -----------------------------------------------------------------------------
FROM node:22-slim

WORKDIR /app

# Install dependencies first so this layer is cached between builds.
COPY package.json .
RUN npm install --omit=dev

COPY server.js ./
COPY public ./public

EXPOSE 3000

# -r newrelic loads the agent before any application code, which is required
# for it to instrument Express and HTTP. Agent settings are NEW_RELIC_*
# environment variables in k8s/portal.yaml (no newrelic.js file needed when
# NEW_RELIC_NO_CONFIG_FILE=true).
CMD ["node", "-r", "newrelic", "server.js"]
