#!/bin/bash
set -e

echo "🚀 Iniciando setup do SaaS Platform..."

# Cria estrutura de pastas
mkdir -p apps/api apps/web packages

# Inicializa monorepo
echo '{
  "name": "saas-platform",
  "private": true,
  "scripts": {
    "dev": "turbo dev",
    "build": "turbo build"
  },
  "devDependencies": {
    "turbo": "^1.10.0"
  }
}' > package.json

# Instala dependências
npm install

# Configura API NestJS
cd apps/api

# Inicializa package.json da API
npm init -y
npm install @nestjs/core @nestjs/common @nestjs/platform-express @nestjs/config @nestjs/jwt @nestjs/passport passport passport-jwt passport-local @prisma/client @nestjs/throttler class-validator class-transformer bcrypt cookie-parser helmet uuid reflect-metadata rxjs
npm install -D @types/node @types/passport-jwt @types/passport-local @types/bcrypt @types/cookie-parser @types/uuid @nestjs/cli prisma ts-node typescript

# Inicializa Prisma
npx prisma init --datasource-provider postgresql

# Cria schema Prisma multi-tenant
cat > prisma/schema.prisma << 'EOL'
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model Tenant {
  id        String   @id @default(uuid())
  name      String
  slug      String   @unique
  plan      String   @default("free")
  settings  Json     @default("{}")
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt
  users     User[]
}

model User {
  id           String   @id @default(uuid())
  tenantId     String
  tenant       Tenant   @relation(fields: [tenantId], references: [id])
  email        String   @unique
  passwordHash String
  name         String
  role         String   @default("viewer")
  createdAt    DateTime @default(now())
  updatedAt    DateTime @updatedAt
}
EOL

# Cria seed
mkdir -p prisma
cat > prisma/seed.ts << 'EOL'
import { PrismaClient } from '@prisma/client';
import * as bcrypt from 'bcrypt';

const prisma = new PrismaClient();

async function main() {
  const tenant = await prisma.tenant.upsert({
    where: { slug: 'demo' },
    update: {},
    create: { name: 'Demo Company', slug: 'demo', plan: 'free' },
  });
  const passwordHash = await bcrypt.hash('admin123', 10);
  const user = await prisma.user.upsert({
    where: { email: 'admin@demo.com' },
    update: {},
    create: { tenantId: tenant.id, email: 'admin@demo.com', passwordHash, name: 'Admin', role: 'owner' },
  });
  console.log('Seed concluído:', { tenant: tenant.slug, user: user.email });
}

main().catch(console.error).finally(() => prisma.$disconnect());
EOL

# Adiciona scripts ao package.json da API
npx npm-add-script -k "start:dev" -v "nest start --watch"
npx npm-add-script -k "build" -v "nest build"
npx npm-add-script -k "prisma:seed" -v "ts-node prisma/seed.ts"

# Volta à raiz
cd ../..

# Configura docker-compose
cat > docker-compose.yml << 'EOL'
version: '3.8'
services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: saas
      POSTGRES_PASSWORD: saas_password
      POSTGRES_DB: saas_platform
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  minio:
    image: minio/minio
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"

volumes:
  postgres_data:
EOL

# Cria .env na API
cat > apps/api/.env << 'EOL'
DATABASE_URL="postgresql://saas:saas_password@localhost:5432/saas_platform?schema=public"
JWT_SECRET="dev-secret"
JWT_REFRESH_SECRET="dev-refresh-secret"
REDIS_HOST=localhost
REDIS_PORT=6379
EOL

# Sobe os serviços
docker-compose up -d

# Espera o PostgreSQL ficar pronto
echo "Aguardando PostgreSQL..."
sleep 10

# Executa migration e seed
cd apps/api
npx prisma migrate dev --name init
npx prisma generate
npx ts-node prisma/seed.ts
cd ../..

echo "✅ Setup concluído! O banco está rodando com dados de teste (admin@demo.com / admin123)."
echo "Acesse o Prisma Studio com: cd apps/api && npx prisma studio"
