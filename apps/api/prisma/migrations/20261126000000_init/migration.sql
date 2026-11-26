-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "audit";

-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "auth";

-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "studio";

-- CreateEnum
CREATE TYPE "studio"."ddl_risk" AS ENUM ('safe', 'review', 'blocked');

-- CreateEnum
CREATE TYPE "studio"."ddl_plan_status" AS ENUM ('draft', 'approved', 'running', 'done', 'failed', 'rejected');

-- CreateTable
CREATE TABLE "auth"."users" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "email" CITEXT NOT NULL,
    "display_name" VARCHAR(120) NOT NULL,
    "password_hash" TEXT NOT NULL,
    "is_framework_admin" BOOLEAN NOT NULL DEFAULT false,
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "failed_count" SMALLINT NOT NULL DEFAULT 0,
    "locked_until" TIMESTAMPTZ(6),
    "notice_ack_at" TIMESTAMPTZ(6),
    "last_seen_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "deleted_at" TIMESTAMPTZ(6),
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "auth"."sessions" (
    "id_hash" BYTEA NOT NULL,
    "user_id" UUID NOT NULL,
    "csrf_token" VARCHAR(64) NOT NULL,
    "ip" INET,
    "user_agent" VARCHAR(400),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expires_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "sessions_pkey" PRIMARY KEY ("id_hash")
);

-- CreateTable
CREATE TABLE "auth"."api_keys" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "name" VARCHAR(80) NOT NULL,
    "prefix" CHAR(8) NOT NULL,
    "key_hash" BYTEA NOT NULL,
    "scopes" TEXT[] DEFAULT ARRAY[]::TEXT[],
    "revoked_at" TIMESTAMPTZ(6),
    "last_used_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "api_keys_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."resource_defs" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "name" VARCHAR(63) NOT NULL,
    "draft" JSONB NOT NULL,
    "published_version" INTEGER,
    "is_system" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "deleted_at" TIMESTAMPTZ(6),
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "resource_defs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."resource_def_versions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "resource_def_id" UUID NOT NULL,
    "version" INTEGER NOT NULL,
    "definition" JSONB NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,

    CONSTRAINT "resource_def_versions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."grid_defs" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "name" VARCHAR(63) NOT NULL,
    "resource" VARCHAR(63) NOT NULL,
    "draft" JSONB NOT NULL,
    "published_version" INTEGER,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "deleted_at" TIMESTAMPTZ(6),
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "grid_defs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."grid_def_versions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "grid_def_id" UUID NOT NULL,
    "version" INTEGER NOT NULL,
    "definition" JSONB NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,

    CONSTRAINT "grid_def_versions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."form_defs" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "name" VARCHAR(63) NOT NULL,
    "resource" VARCHAR(63) NOT NULL,
    "draft" JSONB NOT NULL,
    "published_version" INTEGER,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "deleted_at" TIMESTAMPTZ(6),
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "form_defs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."form_def_versions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "form_def_id" UUID NOT NULL,
    "version" INTEGER NOT NULL,
    "definition" JSONB NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,

    CONSTRAINT "form_def_versions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."grid_views" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "grid_def_id" UUID NOT NULL,
    "user_id" UUID,
    "name" VARCHAR(80) NOT NULL,
    "is_default" BOOLEAN NOT NULL DEFAULT false,
    "state" JSONB NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "deleted_at" TIMESTAMPTZ(6),
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "grid_views_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."menus" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "key" VARCHAR(63) NOT NULL,
    "parent_id" UUID,
    "label" VARCHAR(80) NOT NULL,
    "icon" VARCHAR(40),
    "path" VARCHAR(200),
    "resource" VARCHAR(63),
    "required_right" VARCHAR(20),
    "sort" INTEGER NOT NULL DEFAULT 0,
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "deleted_at" TIMESTAMPTZ(6),
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "menus_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."app_roles" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "code" VARCHAR(40) NOT NULL,
    "name" VARCHAR(80) NOT NULL,
    "description" TEXT,
    "is_system" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "deleted_at" TIMESTAMPTZ(6),
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "app_roles_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."role_grants" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "role_id" UUID NOT NULL,
    "resource" VARCHAR(63) NOT NULL,
    "rights" TEXT[] DEFAULT ARRAY[]::TEXT[],
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "role_grants_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."user_roles" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "user_id" UUID NOT NULL,
    "role_id" UUID NOT NULL,
    "team_id" UUID,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."ddl_plans" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "resource" VARCHAR(63) NOT NULL,
    "base_version" INTEGER,
    "statements" JSONB NOT NULL,
    "risk" "studio"."ddl_risk" NOT NULL,
    "status" "studio"."ddl_plan_status" NOT NULL DEFAULT 'draft',
    "approved_by" UUID,
    "approved_at" TIMESTAMPTZ(6),
    "result" JSONB,
    "backup_file" VARCHAR(300),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_by" UUID,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_by" UUID,
    "row_version" INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT "ddl_plans_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "studio"."releases" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "version" INTEGER NOT NULL,
    "snapshot" JSONB NOT NULL,
    "note" TEXT,
    "rollback_of" INTEGER,
    "published_by" UUID NOT NULL,
    "published_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "releases_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "audit"."data_changes" (
    "id" BIGSERIAL NOT NULL,
    "at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "actor_id" UUID,
    "txid" BIGINT NOT NULL DEFAULT txid_current(),
    "table_name" VARCHAR(130) NOT NULL,
    "row_id" UUID,
    "op" CHAR(1) NOT NULL,
    "old_data" JSONB,
    "new_data" JSONB,
    "changed" TEXT[] DEFAULT ARRAY[]::TEXT[],

    CONSTRAINT "data_changes_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "audit"."def_changes" (
    "id" BIGSERIAL NOT NULL,
    "at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "actor_id" UUID,
    "kind" VARCHAR(20) NOT NULL,
    "name" VARCHAR(63) NOT NULL,
    "action" VARCHAR(20) NOT NULL,
    "version" INTEGER,
    "before" JSONB,
    "after" JSONB,

    CONSTRAINT "def_changes_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "audit"."ddl_runs" (
    "id" BIGSERIAL NOT NULL,
    "at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "actor_id" UUID,
    "plan_id" UUID,
    "statements" TEXT NOT NULL,
    "ok" BOOLEAN NOT NULL,
    "error" TEXT,
    "duration_ms" INTEGER,
    "backup_file" VARCHAR(300),

    CONSTRAINT "ddl_runs_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "users_email_key" ON "auth"."users"("email");

-- CreateIndex
CREATE INDEX "sessions_user_id_idx" ON "auth"."sessions"("user_id");

-- CreateIndex
CREATE INDEX "sessions_expires_at_idx" ON "auth"."sessions"("expires_at");

-- CreateIndex
CREATE UNIQUE INDEX "api_keys_prefix_key" ON "auth"."api_keys"("prefix");

-- CreateIndex
CREATE UNIQUE INDEX "resource_defs_name_key" ON "studio"."resource_defs"("name");

-- CreateIndex
CREATE UNIQUE INDEX "resource_def_versions_resource_def_id_version_key" ON "studio"."resource_def_versions"("resource_def_id", "version");

-- CreateIndex
CREATE UNIQUE INDEX "grid_defs_name_key" ON "studio"."grid_defs"("name");

-- CreateIndex
CREATE INDEX "grid_defs_resource_idx" ON "studio"."grid_defs"("resource");

-- CreateIndex
CREATE UNIQUE INDEX "grid_def_versions_grid_def_id_version_key" ON "studio"."grid_def_versions"("grid_def_id", "version");

-- CreateIndex
CREATE UNIQUE INDEX "form_defs_name_key" ON "studio"."form_defs"("name");

-- CreateIndex
CREATE INDEX "form_defs_resource_idx" ON "studio"."form_defs"("resource");

-- CreateIndex
CREATE UNIQUE INDEX "form_def_versions_form_def_id_version_key" ON "studio"."form_def_versions"("form_def_id", "version");

-- CreateIndex
CREATE INDEX "grid_views_grid_def_id_user_id_idx" ON "studio"."grid_views"("grid_def_id", "user_id");

-- CreateIndex
CREATE UNIQUE INDEX "menus_key_key" ON "studio"."menus"("key");

-- CreateIndex
CREATE INDEX "menus_parent_id_idx" ON "studio"."menus"("parent_id");

-- CreateIndex
CREATE UNIQUE INDEX "app_roles_code_key" ON "studio"."app_roles"("code");

-- CreateIndex
CREATE UNIQUE INDEX "role_grants_role_id_resource_key" ON "studio"."role_grants"("role_id", "resource");

-- CreateIndex
CREATE INDEX "user_roles_role_id_idx" ON "studio"."user_roles"("role_id");

-- CreateIndex
CREATE UNIQUE INDEX "user_roles_user_id_role_id_team_id_key" ON "studio"."user_roles"("user_id", "role_id", "team_id");

-- CreateIndex
CREATE INDEX "ddl_plans_resource_status_idx" ON "studio"."ddl_plans"("resource", "status");

-- CreateIndex
CREATE UNIQUE INDEX "releases_version_key" ON "studio"."releases"("version");

-- CreateIndex
CREATE INDEX "data_changes_table_name_row_id_idx" ON "audit"."data_changes"("table_name", "row_id");

-- CreateIndex
CREATE INDEX "data_changes_at_idx" ON "audit"."data_changes"("at");

-- CreateIndex
CREATE INDEX "def_changes_kind_name_idx" ON "audit"."def_changes"("kind", "name");

-- CreateIndex
CREATE INDEX "def_changes_at_idx" ON "audit"."def_changes"("at");

-- CreateIndex
CREATE INDEX "ddl_runs_plan_id_idx" ON "audit"."ddl_runs"("plan_id");

-- CreateIndex
CREATE INDEX "ddl_runs_at_idx" ON "audit"."ddl_runs"("at");

-- AddForeignKey
ALTER TABLE "auth"."sessions" ADD CONSTRAINT "sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "auth"."api_keys" ADD CONSTRAINT "api_keys_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."resource_def_versions" ADD CONSTRAINT "resource_def_versions_resource_def_id_fkey" FOREIGN KEY ("resource_def_id") REFERENCES "studio"."resource_defs"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."grid_def_versions" ADD CONSTRAINT "grid_def_versions_grid_def_id_fkey" FOREIGN KEY ("grid_def_id") REFERENCES "studio"."grid_defs"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."form_def_versions" ADD CONSTRAINT "form_def_versions_form_def_id_fkey" FOREIGN KEY ("form_def_id") REFERENCES "studio"."form_defs"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."grid_views" ADD CONSTRAINT "grid_views_grid_def_id_fkey" FOREIGN KEY ("grid_def_id") REFERENCES "studio"."grid_defs"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."grid_views" ADD CONSTRAINT "grid_views_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."menus" ADD CONSTRAINT "menus_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "studio"."menus"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."role_grants" ADD CONSTRAINT "role_grants_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "studio"."app_roles"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."user_roles" ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."user_roles" ADD CONSTRAINT "user_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "studio"."app_roles"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."ddl_plans" ADD CONSTRAINT "ddl_plans_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "studio"."releases" ADD CONSTRAINT "releases_published_by_fkey" FOREIGN KEY ("published_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

