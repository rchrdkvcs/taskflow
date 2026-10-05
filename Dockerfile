# syntax=docker/dockerfile:1

FROM node:24-alpine AS api
WORKDIR /app
ENV NODE_ENV=production
COPY api/package.json api/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY --chown=node:node api/src ./src
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]

FROM node:24-alpine AS front-build
WORKDIR /app
COPY front/package.json front/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY front/ ./
RUN npm run build

FROM nginx:stable-alpine AS front
COPY docker/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=front-build /app/dist /usr/share/nginx/html
EXPOSE 80
