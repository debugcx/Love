-- 由 scripts/build-supabase-bootstrap.mjs 生成，请勿手工编辑。
-- 用途：全新 Supabase 项目先执行本文件建立基础表/桶/RPC，再执行 `supabase db push`。
-- 本文件可重复执行（各语句使用 if not exists / drop policy if exists）。

-- ============================================================
-- setup.sql
-- ============================================================
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  avatar_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.couples (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  relationship_start date not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.couple_members (
  couple_id uuid not null references public.couples(id) on delete cascade,
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (couple_id, user_id)
);

create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couples(id) on delete cascade,
  code text not null unique,
  created_by uuid not null references public.profiles(id),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_by uuid references public.profiles(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1)));
  return new;
end;
$$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'on_auth_user_created') then
    create trigger on_auth_user_created after insert on auth.users
    for each row execute function public.handle_new_user();
  end if;
end $$;

create or replace function public.create_couple_with_invitation(couple_name text, relationship_start date)
returns text language plpgsql security definer set search_path = public as $$
declare
  new_couple_id uuid;
  new_code text;
begin
  if exists (select 1 from couple_members where user_id = auth.uid()) then
    raise exception '你已经加入了一个情侣空间';
  end if;
  insert into couples (name, relationship_start, created_by)
  values (couple_name, relationship_start, auth.uid()) returning id into new_couple_id;
  insert into couple_members (couple_id, user_id) values (new_couple_id, auth.uid());
  new_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
  insert into invitations (couple_id, code, created_by) values (new_couple_id, new_code, auth.uid());
  return new_code;
end;
$$;

create or replace function public.accept_couple_invitation(invitation_code text)
returns void language plpgsql security definer set search_path = public as $$
declare target invitations%rowtype;
begin
  if exists (select 1 from couple_members where user_id = auth.uid()) then
    raise exception '你已经加入了一个情侣空间';
  end if;
  select * into target from invitations
  where code = upper(invitation_code) and accepted_at is null and expires_at > now()
  for update;
  if target.id is null then raise exception '邀请码无效或已过期'; end if;
  if (select count(*) from couple_members where couple_id = target.couple_id) >= 2 then
    raise exception '这个空间已经有两位成员';
  end if;
  insert into couple_members (couple_id, user_id) values (target.couple_id, auth.uid());
  update invitations set accepted_by = auth.uid(), accepted_at = now() where id = target.id;
end;
$$;

alter table profiles enable row level security;
alter table couples enable row level security;
alter table couple_members enable row level security;
alter table invitations enable row level security;

create or replace function public.is_couple_member(target_couple_id uuid, target_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.couple_members
    where couple_id = target_couple_id and user_id = target_user_id
  );
$$;

drop policy if exists "profiles read self" on profiles;
drop policy if exists "profiles update self" on profiles;
drop policy if exists "members read own couple" on couple_members;
drop policy if exists "couples read as member" on couples;
drop policy if exists "couples update as member" on couples;
drop policy if exists "invitations read creator" on invitations;
create policy "profiles read self" on profiles for select using (id = auth.uid());
create policy "profiles update self" on profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy "members read own couple" on couple_members for select using (public.is_couple_member(couple_id));
create policy "couples read as member" on couples for select using (
  public.is_couple_member(id)
);
create policy "couples update as member" on couples for update using (
  public.is_couple_member(id)
);
create policy "invitations read creator" on invitations for select using (created_by = auth.uid());

revoke all on function public.create_couple_with_invitation(text, date) from public;
revoke all on function public.accept_couple_invitation(text) from public;
grant execute on function public.create_couple_with_invitation(text, date) to authenticated;
grant execute on function public.accept_couple_invitation(text) to authenticated;


create table if not exists public.memories (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couples(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  content text not null check (char_length(content) between 1 and 1000),
  memory_date date not null,
  location text check (location is null or char_length(location) <= 80),
  photos jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 6),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists memories_couple_date_idx on public.memories (couple_id, memory_date desc);
alter table public.memories enable row level security;
drop policy if exists "memories read by couple" on public.memories;
drop policy if exists "memories create by couple" on public.memories;
drop policy if exists "memories update by author" on public.memories;
drop policy if exists "memories delete by author" on public.memories;
create policy "memories read by couple" on public.memories for select using (public.is_couple_member(couple_id));
create policy "memories create by couple" on public.memories for insert with check (public.is_couple_member(couple_id) and author_id = auth.uid());
create policy "memories update by author" on public.memories for update using (author_id = auth.uid() and public.is_couple_member(couple_id)) with check (author_id = auth.uid() and public.is_couple_member(couple_id));
create policy "memories delete by author" on public.memories for delete using (author_id = auth.uid() and public.is_couple_member(couple_id));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('memory-photos', 'memory-photos', false, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "memory photos read by couple" on storage.objects;
drop policy if exists "memory photos upload by couple" on storage.objects;
drop policy if exists "memory photos delete by couple" on storage.objects;
create policy "memory photos read by couple" on storage.objects for select using (
  bucket_id = 'memory-photos' and public.is_couple_member((storage.foldername(name))[1]::uuid)
);
create policy "memory photos upload by couple" on storage.objects for insert with check (
  bucket_id = 'memory-photos' and public.is_couple_member((storage.foldername(name))[1]::uuid)
);
create policy "memory photos delete by couple" on storage.objects for delete using (
  bucket_id = 'memory-photos' and public.is_couple_member((storage.foldername(name))[1]::uuid)
);

-- ============================================================
-- setup_messages.sql
-- ============================================================
create table if not exists public.messages(
 id uuid primary key default gen_random_uuid(),couple_id uuid not null references public.couples(id) on delete cascade,
 sender_id uuid not null references public.profiles(id),content text check(content is null or char_length(content)<=2000),
 image_path text,read_at timestamptz,created_at timestamptz not null default now(),
 check(content is not null or image_path is not null)
);
create index if not exists messages_couple_created_idx on public.messages(couple_id,created_at desc);
alter table public.messages enable row level security;
drop policy if exists "messages read by couple" on public.messages;drop policy if exists "messages create by couple" on public.messages;drop policy if exists "messages update recipient" on public.messages;drop policy if exists "messages delete sender" on public.messages;
create policy "messages read by couple" on public.messages for select using(public.is_couple_member(couple_id));
create policy "messages create by couple" on public.messages for insert with check(public.is_couple_member(couple_id) and sender_id=auth.uid());
create policy "messages update recipient" on public.messages for update using(public.is_couple_member(couple_id) and sender_id<>auth.uid()) with check(public.is_couple_member(couple_id));
create policy "messages delete sender" on public.messages for delete using(sender_id=auth.uid());
drop policy if exists "message images read by couple" on storage.objects;drop policy if exists "message images upload by couple" on storage.objects;
create policy "message images read by couple" on storage.objects for select using(bucket_id='memory-photos' and (storage.foldername(name))[2]='messages' and public.is_couple_member((storage.foldername(name))[1]::uuid));
create policy "message images upload by couple" on storage.objects for insert with check(bucket_id='memory-photos' and (storage.foldername(name))[2]='messages' and public.is_couple_member((storage.foldername(name))[1]::uuid));
do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='messages') then
  alter publication supabase_realtime add table public.messages;
 end if;
end $$;

-- ============================================================
-- setup_albums.sql
-- ============================================================
create table if not exists public.albums (
  id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade,
  created_by uuid not null references public.profiles(id), name text not null check (char_length(name) between 1 and 40),
  description text check (description is null or char_length(description) <= 160), cover_path text, created_at timestamptz not null default now()
);
create table if not exists public.album_photos (
  id uuid primary key default gen_random_uuid(), album_id uuid not null references public.albums(id) on delete cascade,
  uploaded_by uuid not null references public.profiles(id), path text not null unique, caption text check (caption is null or char_length(caption) <= 200),
  taken_date date not null default current_date, created_at timestamptz not null default now()
);
alter table public.albums enable row level security; alter table public.album_photos enable row level security;
drop policy if exists "albums read by couple" on public.albums; drop policy if exists "albums create by couple" on public.albums; drop policy if exists "albums update by creator" on public.albums; drop policy if exists "albums delete by creator" on public.albums;
create policy "albums read by couple" on public.albums for select using (public.is_couple_member(couple_id));
create policy "albums create by couple" on public.albums for insert with check (public.is_couple_member(couple_id) and created_by = auth.uid());
create policy "albums update by creator" on public.albums for update using (created_by = auth.uid());
create policy "albums delete by creator" on public.albums for delete using (created_by = auth.uid());
drop policy if exists "album photos read by couple" on public.album_photos; drop policy if exists "album photos create by couple" on public.album_photos; drop policy if exists "album photos delete by uploader" on public.album_photos; drop policy if exists "album photos delete by couple" on public.album_photos;
create policy "album photos read by couple" on public.album_photos for select using (exists(select 1 from public.albums where id = album_id and public.is_couple_member(couple_id)));
create policy "album photos create by couple" on public.album_photos for insert with check (uploaded_by = auth.uid() and exists(select 1 from public.albums where id = album_id and public.is_couple_member(couple_id)));
create policy "album photos delete by couple" on public.album_photos for delete using (exists(select 1 from public.albums where id = album_id and public.is_couple_member(couple_id)));

-- ============================================================
-- setup_anniversaries.sql
-- ============================================================
create table if not exists public.anniversaries(
 id uuid primary key default gen_random_uuid(),couple_id uuid not null references public.couples(id) on delete cascade,
 created_by uuid not null references public.profiles(id),title text not null check(char_length(title) between 1 and 80),
 event_date date not null,kind text not null default 'custom' check(kind in('anniversary','birthday','travel','custom')),
 recurring boolean not null default true,note text check(note is null or char_length(note)<=300),created_at timestamptz not null default now()
);
create index if not exists anniversaries_couple_idx on public.anniversaries(couple_id,event_date);
alter table public.anniversaries enable row level security;
drop policy if exists "anniversaries read by couple" on public.anniversaries;drop policy if exists "anniversaries create by couple" on public.anniversaries;drop policy if exists "anniversaries update by couple" on public.anniversaries;drop policy if exists "anniversaries delete by creator" on public.anniversaries;
create policy "anniversaries read by couple" on public.anniversaries for select using(public.is_couple_member(couple_id));
create policy "anniversaries create by couple" on public.anniversaries for insert with check(public.is_couple_member(couple_id) and created_by=auth.uid());
create policy "anniversaries update by couple" on public.anniversaries for update using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id));
create policy "anniversaries delete by creator" on public.anniversaries for delete using(created_by=auth.uid());

-- ============================================================
-- setup_together_list.sql
-- ============================================================
create table if not exists public.together_items (
  id uuid primary key default gen_random_uuid(), couple_id uuid not null references public.couples(id) on delete cascade,
  created_by uuid not null references public.profiles(id), title text not null check(char_length(title) between 1 and 100),
  note text check(note is null or char_length(note)<=500), category text not null check(category in('wish','travel','movie','date')),
  priority text not null default 'normal' check(priority in('low','normal','high')), planned_date date,
  completed boolean not null default false, completed_by uuid references public.profiles(id), completed_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists together_items_couple_idx on public.together_items(couple_id,completed,created_at desc);
alter table public.together_items enable row level security;
drop policy if exists "list read by couple" on public.together_items;drop policy if exists "list create by couple" on public.together_items;drop policy if exists "list update by couple" on public.together_items;drop policy if exists "list delete by creator" on public.together_items;
create policy "list read by couple" on public.together_items for select using(public.is_couple_member(couple_id));
create policy "list create by couple" on public.together_items for insert with check(public.is_couple_member(couple_id) and created_by=auth.uid());
create policy "list update by couple" on public.together_items for update using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id) and (completed_by is null or public.is_couple_member(couple_id,completed_by)));
create policy "list delete by creator" on public.together_items for delete using(created_by=auth.uid());

-- ============================================================
-- setup_account_management.sql
-- ============================================================
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('avatars','avatars',false,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
drop policy if exists "avatars read by authenticated" on storage.objects;drop policy if exists "avatars upload own" on storage.objects;drop policy if exists "avatars update own" on storage.objects;
create policy "avatars read by authenticated" on storage.objects for select to authenticated using(bucket_id='avatars');
create policy "avatars upload own" on storage.objects for insert to authenticated with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "avatars update own" on storage.objects for update to authenticated using(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);
create or replace function public.get_couple_profiles() returns table(user_id uuid,display_name text,avatar_url text) language sql stable security definer set search_path=public as $$ select p.id,p.display_name,p.avatar_url from profiles p join couple_members cm on cm.user_id=p.id where cm.couple_id=(select couple_id from couple_members where user_id=auth.uid()) $$;
create or replace function public.regenerate_couple_invitation() returns text language plpgsql security definer set search_path=public as $$ declare cid uuid;code text;begin select couple_id into cid from couple_members where user_id=auth.uid();if cid is null then raise exception '尚未加入情侣空间';end if;update invitations set expires_at=now() where couple_id=cid and accepted_at is null;code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));insert into invitations(couple_id,code,created_by)values(cid,code,auth.uid());return code;end;$$;
create or replace function public.leave_couple_space() returns void language plpgsql security definer set search_path=public as $$ begin delete from couple_members where user_id=auth.uid();end;$$;
revoke all on function public.get_couple_profiles() from public;revoke all on function public.regenerate_couple_invitation() from public;revoke all on function public.leave_couple_space() from public;
grant execute on function public.get_couple_profiles() to authenticated;grant execute on function public.regenerate_couple_invitation() to authenticated;grant execute on function public.leave_couple_space() to authenticated;

-- ============================================================
-- setup_heart_ai.sql
-- ============================================================
create table if not exists public.daily_questions(
 id uuid primary key default gen_random_uuid(),couple_id uuid not null references public.couples(id) on delete cascade,
 question_date date not null default current_date,question text not null,category text not null default 'daily',
 created_at timestamptz not null default now(),unique(couple_id,question_date)
);
create table if not exists public.daily_answers(
 id uuid primary key default gen_random_uuid(),question_id uuid not null references public.daily_questions(id) on delete cascade,
 user_id uuid not null references public.profiles(id),answer text not null check(char_length(answer) between 1 and 1000),
 created_at timestamptz not null default now(),unique(question_id,user_id)
);
create table if not exists public.ai_generations(
 id uuid primary key default gen_random_uuid(),couple_id uuid not null references public.couples(id) on delete cascade,
 user_id uuid not null references public.profiles(id),feature text not null,input_summary text,output text not null,
 provider text not null default 'xiaomi-mimo',model text,created_at timestamptz not null default now()
);
alter table public.daily_questions enable row level security;alter table public.daily_answers enable row level security;alter table public.ai_generations enable row level security;
create or replace function public.daily_answer_count(target_question_id uuid) returns bigint language sql stable security definer set search_path=public as $$select count(*) from public.daily_answers where question_id=target_question_id$$;
drop policy if exists "questions read couple" on public.daily_questions;drop policy if exists "questions create couple" on public.daily_questions;
create policy "questions read couple" on public.daily_questions for select using(public.is_couple_member(couple_id));
create policy "questions create couple" on public.daily_questions for insert with check(public.is_couple_member(couple_id));
drop policy if exists "answers read after both" on public.daily_answers;drop policy if exists "answers create self" on public.daily_answers;drop policy if exists "answers update self" on public.daily_answers;
create policy "answers read after both" on public.daily_answers for select using(user_id=auth.uid() or public.daily_answer_count(question_id)>=2);
create policy "answers create self" on public.daily_answers for insert with check(user_id=auth.uid() and exists(select 1 from public.daily_questions q where q.id=question_id and public.is_couple_member(q.couple_id)));
create policy "answers update self" on public.daily_answers for update using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "ai history read couple" on public.ai_generations;drop policy if exists "ai history create self" on public.ai_generations;
create policy "ai history read couple" on public.ai_generations for select using(public.is_couple_member(couple_id));
create policy "ai history create self" on public.ai_generations for insert with check(user_id=auth.uid() and public.is_couple_member(couple_id));
notify pgrst,'reload schema';

-- ============================================================
-- setup_couple_cover.sql
-- ============================================================
alter table public.couples add column if not exists cover_path text;
notify pgrst, 'reload schema';

-- ============================================================
-- upgrade_message_media.sql
-- ============================================================
alter table public.messages add column if not exists media_path text;
alter table public.messages add column if not exists media_type text;
alter table public.messages drop constraint if exists messages_check;
alter table public.messages drop constraint if exists messages_content_or_media_check;
alter table public.messages add constraint messages_content_or_media_check check(content is not null or image_path is not null or media_path is not null);
alter table public.messages drop constraint if exists messages_media_type_check;
alter table public.messages add constraint messages_media_type_check check(media_type is null or media_type in ('image','video','audio'));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('message-media','message-media',false,41943040,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','audio/webm','audio/ogg','audio/mp4','audio/mpeg'])
on conflict(id) do update set file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "message media read by couple" on storage.objects;
drop policy if exists "message media upload by couple" on storage.objects;
drop policy if exists "message media delete by couple" on storage.objects;
create policy "message media read by couple" on storage.objects for select using(bucket_id='message-media' and (storage.foldername(name))[2]='messages' and public.is_couple_member((storage.foldername(name))[1]::uuid));
create policy "message media upload by couple" on storage.objects for insert with check(bucket_id='message-media' and (storage.foldername(name))[2]='messages' and public.is_couple_member((storage.foldername(name))[1]::uuid));
create policy "message media delete by couple" on storage.objects for delete using(bucket_id='message-media' and (storage.foldername(name))[2]='messages' and public.is_couple_member((storage.foldername(name))[1]::uuid));

-- ============================================================
-- upgrade_album_media.sql
-- ============================================================
alter table public.album_photos add column if not exists media_type text not null default 'image';
alter table public.album_photos drop constraint if exists album_photos_media_type_check;
alter table public.album_photos add constraint album_photos_media_type_check check(media_type in ('image','video'));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('album-media','album-media',false,52428800,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict(id) do update set file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "album media read couple" on storage.objects;drop policy if exists "album media upload couple" on storage.objects;drop policy if exists "album media delete uploader" on storage.objects;
create policy "album media read couple" on storage.objects for select using(bucket_id='album-media' and public.is_couple_member((storage.foldername(name))[1]::uuid));
create policy "album media upload couple" on storage.objects for insert with check(bucket_id='album-media' and public.is_couple_member((storage.foldername(name))[1]::uuid));
create policy "album media delete uploader" on storage.objects for delete using(bucket_id='album-media' and public.is_couple_member((storage.foldername(name))[1]::uuid));
notify pgrst,'reload schema';

-- ============================================================
-- upgrade_couple_letters.sql
-- ============================================================
create table if not exists public.couple_letters(
 id uuid primary key default gen_random_uuid(),couple_id uuid not null references public.couples(id) on delete cascade,
 sender_id uuid not null references public.profiles(id),recipient_id uuid not null references public.profiles(id),
 content text not null check(char_length(content) between 1 and 1200),created_at timestamptz not null default now(),
 check(sender_id<>recipient_id)
);
create index if not exists couple_letters_recipient_idx on public.couple_letters(couple_id,recipient_id,created_at desc);
alter table public.couple_letters enable row level security;
drop policy if exists "letters read couple" on public.couple_letters;drop policy if exists "letters send to partner" on public.couple_letters;drop policy if exists "letters delete sender" on public.couple_letters;
create policy "letters read couple" on public.couple_letters for select using(public.is_couple_member(couple_id) and (sender_id=auth.uid() or recipient_id=auth.uid()));
create policy "letters send to partner" on public.couple_letters for insert with check(sender_id=auth.uid() and public.is_couple_member(couple_id) and exists(select 1 from public.couple_members cm where cm.couple_id=couple_letters.couple_id and cm.user_id=recipient_id));
create policy "letters delete sender" on public.couple_letters for delete using(sender_id=auth.uid());
notify pgrst,'reload schema';

-- ============================================================
-- upgrade_love_letter.sql
-- ============================================================
alter table public.couples add column if not exists love_letter text check(love_letter is null or char_length(love_letter) <= 1200);

-- ============================================================
-- upgrade_ai_works.sql
-- ============================================================
create table if not exists public.ai_saved_works(
 id uuid primary key default gen_random_uuid(),couple_id uuid not null references public.couples(id) on delete cascade,
 user_id uuid not null references public.profiles(id),kind text not null check(kind in ('diary','love_letter')),
 work_date date not null default current_date,title text not null,content text not null check(char_length(content) between 1 and 5000),
 memory_id uuid references public.memories(id) on delete set null,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create unique index if not exists ai_saved_diary_per_day on public.ai_saved_works(couple_id,kind,work_date) where kind='diary';
alter table public.ai_saved_works enable row level security;
drop policy if exists "ai works read couple" on public.ai_saved_works;drop policy if exists "ai works write couple" on public.ai_saved_works;drop policy if exists "ai works update couple" on public.ai_saved_works;drop policy if exists "ai works delete couple" on public.ai_saved_works;
create policy "ai works read couple" on public.ai_saved_works for select using(public.is_couple_member(couple_id));
create policy "ai works write couple" on public.ai_saved_works for insert with check(user_id=auth.uid() and public.is_couple_member(couple_id));
create policy "ai works update couple" on public.ai_saved_works for update using(public.is_couple_member(couple_id)) with check(public.is_couple_member(couple_id));
create policy "ai works delete couple" on public.ai_saved_works for delete using(public.is_couple_member(couple_id));
notify pgrst,'reload schema';

-- ============================================================
-- upgrade_ai_date_plans.sql
-- ============================================================
alter table public.ai_saved_works drop constraint if exists ai_saved_works_kind_check;
alter table public.ai_saved_works add constraint ai_saved_works_kind_check check(kind in ('date_plan','diary','love_letter'));
notify pgrst,'reload schema';

-- ============================================================
-- hotfix_invitation_code.sql
-- ============================================================
create or replace function public.create_couple_with_invitation(couple_name text, relationship_start date)
returns text language plpgsql security definer set search_path = public as $$
declare
  new_couple_id uuid;
  new_code text;
begin
  if auth.uid() is null then
    raise exception '请先登录';
  end if;
  if exists (select 1 from couple_members where user_id = auth.uid()) then
    raise exception '你已经加入了一个情侣空间';
  end if;
  insert into couples (name, relationship_start, created_by)
  values (couple_name, relationship_start, auth.uid()) returning id into new_couple_id;
  insert into couple_members (couple_id, user_id) values (new_couple_id, auth.uid());
  new_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into invitations (couple_id, code, created_by) values (new_couple_id, new_code, auth.uid());
  return new_code;
end;
$$;

revoke all on function public.create_couple_with_invitation(text, date) from public;
grant execute on function public.create_couple_with_invitation(text, date) to authenticated;
