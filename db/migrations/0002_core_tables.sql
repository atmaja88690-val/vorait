-- 0002 — Tabel inti ds_monitoring (Design §3.3, T-005). Dijalankan runner sebagai mon_schema.
-- Kolom standar GridBuilder §3 di setiap tabel: id, created_at, created_by, updated_at, updated_by, deleted_at, row_version.
-- created_by/updated_by/user_id/author_id merujuk auth.users TANPA FK: auth dikelola jalur Prisma (D-3) —
-- FK lintas jalur akan mengunci perubahan Prisma. Keabsahannya dicek di servis.
-- Semua FK ON DELETE RESTRICT. Penghapusan = soft delete (deleted_at); mon_app tidak punya DELETE.
-- Trigger (fn_touch, fn_audit, penjaga) menyusul di T-006.

SET LOCAL search_path = ds_monitoring, public;  -- hanya untuk transaksi berkas ini

-- ───────────── organisasi ─────────────
CREATE TABLE teams (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code           varchar(20)  NOT NULL UNIQUE,
  name           varchar(80)  NOT NULL,
  default_method text         NOT NULL DEFAULT 'scrum' CHECK (default_method IN ('scrum', 'kanban')),
  is_active      boolean      NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);

CREATE TABLE positions (
  id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(80) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);

CREATE TABLE employees (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid UNIQUE,                       -- auth.users.id (tanpa FK, lihat kepala berkas)
  full_name          varchar(120) NOT NULL,
  position_id        uuid REFERENCES positions (id) ON DELETE RESTRICT,
  contact_email      varchar(254),
  telegram_chat_id   bigint UNIQUE,
  telegram_linked_at timestamptz,
  is_active          boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  CHECK ((telegram_chat_id IS NULL) = (telegram_linked_at IS NULL))
);
CREATE INDEX employees_position_idx ON employees (position_id);

CREATE TABLE telegram_link_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees (id) ON DELETE RESTRICT,
  token_hash  bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),  -- sha256 dari token acak 32 byte
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);
CREATE INDEX telegram_link_tokens_employee_idx ON telegram_link_tokens (employee_id);

CREATE TABLE team_members (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id     uuid NOT NULL REFERENCES teams (id) ON DELETE RESTRICT,
  employee_id uuid NOT NULL REFERENCES employees (id) ON DELETE RESTRICT,
  is_lead     boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (team_id, employee_id)
);
CREATE INDEX team_members_employee_idx ON team_members (employee_id);

-- ───────────── proyek & alur kerja ─────────────
CREATE TABLE projects (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code         varchar(20)  NOT NULL UNIQUE CHECK (code ~ '^[A-Z][A-Z0-9]{1,19}$'),  -- awalan item_key, mis. WEB
  name         varchar(150) NOT NULL,
  description  text,
  team_id      uuid NOT NULL REFERENCES teams (id) ON DELETE RESTRICT,
  method       text NOT NULL CHECK (method IN ('scrum', 'kanban')),
  pic_id       uuid REFERENCES employees (id) ON DELETE RESTRICT,
  start_date   date,
  target_date  date,
  status       text NOT NULL DEFAULT 'plan' CHECK (status IN ('plan', 'active', 'hold', 'done')),
  next_item_no int  NOT NULL DEFAULT 1 CHECK (next_item_no >= 1),  -- penghitung item_key (dikunci FOR UPDATE di servis)
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  CHECK (target_date IS NULL OR start_date IS NULL OR target_date >= start_date)
);
CREATE INDEX projects_team_idx ON projects (team_id);
CREATE INDEX projects_pic_idx ON projects (pic_id);

CREATE TABLE item_types (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id   uuid NOT NULL REFERENCES teams (id) ON DELETE RESTRICT,
  code      varchar(20) NOT NULL,
  name      varchar(60) NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (team_id, code)
);

CREATE TABLE workflow_statuses (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  method      text NOT NULL CHECK (method IN ('scrum', 'kanban')),
  code        varchar(30) NOT NULL,
  name        varchar(60) NOT NULL,
  category    text NOT NULL CHECK (category IN ('todo', 'doing', 'review', 'done', 'cancel')),
  sort        int  NOT NULL DEFAULT 0,
  color_token varchar(30),
  wip_limit   int CHECK (wip_limit IS NULL OR wip_limit > 0),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (method, code)
);

CREATE TABLE workflow_transitions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  method          text NOT NULL,
  from_code       varchar(30) NOT NULL,
  to_code         varchar(30) NOT NULL,
  roles           text[] NOT NULL DEFAULT '{}',
  reason_required boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (method, from_code, to_code),
  CHECK (from_code <> to_code),
  FOREIGN KEY (method, from_code) REFERENCES workflow_statuses (method, code) ON DELETE RESTRICT,
  FOREIGN KEY (method, to_code)   REFERENCES workflow_statuses (method, code) ON DELETE RESTRICT
);

CREATE TABLE sprints (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects (id) ON DELETE RESTRICT,
  name       varchar(80) NOT NULL,
  goal       text,
  start_date date NOT NULL,
  end_date   date NOT NULL,
  status     text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'active', 'closed')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  CHECK (end_date >= start_date)
);
-- Satu sprint aktif per proyek (FR-17)
CREATE UNIQUE INDEX sprints_satu_aktif_per_proyek ON sprints (project_id) WHERE status = 'active' AND deleted_at IS NULL;

CREATE TABLE work_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES projects (id) ON DELETE RESTRICT,
  sprint_id    uuid REFERENCES sprints (id) ON DELETE RESTRICT,
  item_key     varchar(30) NOT NULL UNIQUE,
  type_id      uuid NOT NULL REFERENCES item_types (id) ON DELETE RESTRICT,
  title        varchar(200) NOT NULL,
  description  text,
  status_code  varchar(30) NOT NULL,       -- dicocokkan dengan workflow_statuses(method proyek) di servis + trigger T-006
  priority     text NOT NULL DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high', 'urgent')),
  assignee_id  uuid REFERENCES employees (id) ON DELETE RESTRICT,
  story_points smallint CHECK (story_points IN (0, 1, 2, 3, 5, 8, 13)),
  progress     smallint NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  due_date     date,
  labels       text[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);
CREATE INDEX work_items_project_status_idx ON work_items (project_id, status_code);
CREATE INDEX work_items_sprint_idx ON work_items (sprint_id);
CREATE INDEX work_items_assignee_idx ON work_items (assignee_id);
CREATE INDEX work_items_type_idx ON work_items (type_id);

-- Hanya INSERT (diisi trigger T-006)
CREATE TABLE work_item_status_history (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id    uuid NOT NULL REFERENCES work_items (id) ON DELETE RESTRICT,
  from_code  varchar(30),
  to_code    varchar(30) NOT NULL,
  points     smallint,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);
CREATE INDEX work_item_status_history_item_idx ON work_item_status_history (item_id, changed_at);

-- ───────────── kalender & standup (D-9: tiga tabel terpisah) ─────────────
CREATE TABLE calendar_categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        varchar(30) NOT NULL UNIQUE,
  name        varchar(60) NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('work', 'meeting', 'incident', 'duty', 'leave')),
  color_token varchar(30),
  sort        int NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);

CREATE TABLE event_series (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule       text NOT NULL CHECK (rule IN ('daily_workdays', 'weekly')),
  until_date date NOT NULL,                -- batas 60 kejadian ditegakkan servis (FR-24e)
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);

CREATE TABLE calendar_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  uuid NOT NULL REFERENCES employees (id) ON DELETE RESTRICT,
  category_id  uuid NOT NULL REFERENCES calendar_categories (id) ON DELETE RESTRICT,
  event_date   date NOT NULL,
  all_day      boolean NOT NULL DEFAULT false,
  start_min    smallint,                   -- menit sejak 00:00 WITA, kelipatan 15
  duration_min smallint,
  title        varchar(200) NOT NULL,
  project_id   uuid REFERENCES projects (id) ON DELETE RESTRICT,
  status       text NOT NULL DEFAULT 'plan' CHECK (status IN ('plan', 'done', 'cancelled')),
  series_id    uuid REFERENCES event_series (id) ON DELETE RESTRICT,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  -- Bentuk waktu (Design §3.3): sepanjang hari tanpa jam, atau slot 15 menit yang tidak melewati tengah malam.
  -- Koreksi atas Design: tambahan "IS NOT NULL" — tanpa itu kegiatan berjam dengan start_min/duration_min NULL
  -- menghasilkan CHECK = NULL dan LOLOS (CHECK hanya menolak FALSE). Terbukti di uji T-005.
  CONSTRAINT calendar_events_bentuk_waktu CHECK (
    (all_day AND start_min IS NULL AND duration_min IS NULL)
    OR (NOT all_day AND start_min IS NOT NULL AND duration_min IS NOT NULL
        AND start_min BETWEEN 0 AND 1425 AND start_min % 15 = 0
        AND duration_min >= 15 AND duration_min % 15 = 0 AND start_min + duration_min <= 1440)
  )
);
CREATE INDEX calendar_events_tanggal_karyawan_idx ON calendar_events (event_date, employee_id);
CREATE INDEX calendar_events_employee_idx ON calendar_events (employee_id, event_date);
CREATE INDEX calendar_events_project_idx ON calendar_events (project_id);
CREATE INDEX calendar_events_series_idx ON calendar_events (series_id);

-- Tautan informatif kegiatan → item (tidak mengubah status item)
CREATE TABLE calendar_event_items (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES calendar_events (id) ON DELETE RESTRICT,
  item_id  uuid NOT NULL REFERENCES work_items (id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (event_id, item_id)
);
CREATE INDEX calendar_event_items_item_idx ON calendar_event_items (item_id);

-- Standup: satu per karyawan per hari (FR-21a)
CREATE TABLE daily_logs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees (id) ON DELETE RESTRICT,
  log_date    date NOT NULL,
  yesterday   text NOT NULL DEFAULT '',
  today       text NOT NULL DEFAULT '',
  blockers    text NOT NULL DEFAULT '',
  has_blocker boolean GENERATED ALWAYS AS (btrim(blockers) <> '') STORED,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (employee_id, log_date)
);
CREATE INDEX daily_logs_tanggal_idx ON daily_logs (log_date);

-- Pembaruan item lewat standup (satu-satunya jalur ubah status item, D-9)
CREATE TABLE daily_log_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  log_id      uuid NOT NULL REFERENCES daily_logs (id) ON DELETE RESTRICT,
  item_id     uuid NOT NULL REFERENCES work_items (id) ON DELETE RESTRICT,
  status_to   varchar(30),
  progress_to smallint CHECK (progress_to IS NULL OR progress_to BETWEEN 0 AND 100),
  note        text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (log_id, item_id)
);
CREATE INDEX daily_log_items_item_idx ON daily_log_items (item_id);

CREATE TABLE log_comments (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  log_id    uuid NOT NULL REFERENCES daily_logs (id) ON DELETE RESTRICT,
  parent_id uuid REFERENCES log_comments (id) ON DELETE RESTRICT,
  author_id uuid NOT NULL,                 -- auth.users.id (Administrator belum tentu karyawan)
  body      text NOT NULL CHECK (btrim(body) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);
CREATE INDEX log_comments_log_idx ON log_comments (log_id);

-- ───────────── hari kerja (D-5) ─────────────
CREATE TABLE work_calendar (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekday    smallint NOT NULL UNIQUE CHECK (weekday BETWEEN 1 AND 7),  -- ISO: 1 = Senin … 7 = Minggu
  is_workday boolean  NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);

CREATE TABLE holidays (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  holiday_date date NOT NULL UNIQUE,
  name         varchar(120) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);

-- ───────────── lain-lain ─────────────
CREATE TABLE notes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid REFERENCES projects (id) ON DELETE RESTRICT,
  item_id    uuid REFERENCES work_items (id) ON DELETE RESTRICT,
  title      varchar(200) NOT NULL,
  content    jsonb NOT NULL DEFAULT '{}',  -- dokumen TipTap
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  CHECK (num_nonnulls(project_id, item_id) = 1)
);
CREATE INDEX notes_project_idx ON notes (project_id);
CREATE INDEX notes_item_idx ON notes (item_id);

CREATE TABLE files (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_table   varchar(63)  NOT NULL,
  owner_id      uuid         NOT NULL,
  original_name varchar(255) NOT NULL,
  mime          varchar(100) NOT NULL,
  size          bigint       NOT NULL CHECK (size >= 0),
  sha256        char(64)     NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  path          varchar(300) NOT NULL UNIQUE,  -- relatif terhadap /var/lib/vora-kegiatan/uploads
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);
CREATE INDEX files_owner_idx ON files (owner_table, owner_id);

CREATE TABLE notifications_sent (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees (id) ON DELETE RESTRICT,
  ref_date    date NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('reminder', 'digest')),
  channel     varchar(20) NOT NULL DEFAULT 'telegram',
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1,
  UNIQUE (employee_id, ref_date, kind)
);

CREATE TABLE in_app_notifications (
  id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,                   -- auth.users.id
  kind    varchar(30) NOT NULL,
  ref     jsonb NOT NULL DEFAULT '{}',
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  deleted_at timestamptz, row_version int NOT NULL DEFAULT 1
);
CREATE INDEX in_app_notifications_belum_dibaca_idx ON in_app_notifications (user_id) WHERE read_at IS NULL;
