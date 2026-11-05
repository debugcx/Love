// 生成 supabase/bootstrap.sql：把迁移依赖的 setup/upgrade 一次性初始化脚本
// 按正确顺序拼成一个文件。源文件仍是唯一真源；修改后重新运行本脚本。
import { readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const files = [
  'setup.sql',
  'setup_messages.sql',
  'setup_albums.sql',
  'setup_anniversaries.sql',
  'setup_together_list.sql',
  'setup_account_management.sql',
  'setup_heart_ai.sql',
  'setup_couple_cover.sql',
  'upgrade_message_media.sql',
  'upgrade_album_media.sql',
  'upgrade_couple_letters.sql',
  'upgrade_love_letter.sql',
  'upgrade_ai_works.sql',
  'upgrade_ai_date_plans.sql',
  'hotfix_invitation_code.sql',
]

const parts = [
  '-- 由 scripts/build-supabase-bootstrap.mjs 生成，请勿手工编辑。',
  '-- 用途：全新 Supabase 项目先执行本文件建立基础表/桶/RPC，再执行 `supabase db push`。',
  '-- 本文件可重复执行（各语句使用 if not exists / drop policy if exists）。',
  '',
]

for (const file of files) {
  const sql = (await readFile(join(root, 'supabase', file), 'utf8')).replace(/^\uFEFF/, '').trim()
  parts.push(
    '-- ============================================================',
    `-- ${file}`,
    '-- ============================================================',
    sql,
    '',
  )
}

const target = join(root, 'supabase', 'bootstrap.sql')
await writeFile(target, parts.join('\n'), 'utf8')
console.log(`wrote ${target} (${files.length} files)`)
