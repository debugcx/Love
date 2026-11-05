import { describe, expect, it } from 'vitest'
import {
  persistUploadJobs,
  restorePersistedJobs,
  restoredJobPatch,
  uploadQueueStorageKey,
} from '../app/utils/uploadQueuePersistence'

describe('upload queue persistence', () => {
  it('restores unfinished jobs while preserving terminal failures', () => {
    const jobs = restorePersistedJobs(JSON.stringify([
      { id: 'queued', name: 'photo.jpg', status: 'uploading', error: '', uppyFileId: 'uppy-1' },
      { id: 'failed', name: 'video.mp4', status: 'failed', error: '网络错误' },
    ]))

    expect(jobs[0]).toMatchObject({ id: 'queued', status: 'paused', restored: true })
    expect(jobs[1]).toMatchObject({ id: 'failed', status: 'failed', error: '网络错误' })
  })

  it('rejects malformed queue data instead of breaking app startup', () => {
    expect(restorePersistedJobs('{broken')).toEqual([])
    expect(restorePersistedJobs(JSON.stringify({ id: 'not-an-array' }))).toEqual([])
  })

  it('maps an Uppy restored file to a resumable business job', () => {
    expect(restoredJobPatch({
      id: 'uppy-1',
      name: 'photo.jpg',
      size: 2048,
      meta: { jobId: 'job-1', displayName: '相册 · photo.jpg', operation: { kind: 'album', albumId: 'album-1' } },
    })).toMatchObject({
      id: 'job-1',
      name: '相册 · photo.jpg',
      size: 2048,
      status: 'paused',
      restored: true,
      operation: { kind: 'album', albumId: 'album-1' },
    })
  })

  it('marks a missing IndexedDB blob as a ghost', () => {
    expect(restoredJobPatch({ id: 'uppy-2', meta: { jobId: 'job-2' }, isGhost: true })).toMatchObject({
      id: 'job-2',
      error: '浏览器未能恢复文件内容，请重新选择文件',
    })
  })

  it('writes unfinished jobs under the shared key and can restore them', () => {
    const store = new Map<string, string>()
    const storage = { setItem: (key: string, value: string) => { store.set(key, value) } }
    persistUploadJobs(storage, [
      { id: 'done', status: 'completed' },
      { id: 'uploading', status: 'uploading', uppyFileId: 'uppy-1', name: 'a.jpg', size: 1, progress: 40, attempts: 1, error: '', createdAt: '2026-01-01T00:00:00.000Z' },
      { id: 'failed', status: 'failed', name: 'b.mp4', size: 2, progress: 0, attempts: 3, error: '网络错误', createdAt: '2026-01-01T00:00:00.000Z' },
    ])

    const raw = store.get(uploadQueueStorageKey)
    expect(raw).toBeTruthy()
    const restored = restorePersistedJobs(raw || null)
    expect(restored.map((job) => job.id)).toEqual(['uploading', 'failed'])
    expect(restored[0]).toMatchObject({ id: 'uploading', status: 'paused', restored: true })
    expect(restored[1]).toMatchObject({ id: 'failed', status: 'failed', error: '网络错误' })
  })

  it('keeps only the latest 30 unfinished jobs', () => {
    const store = new Map<string, string>()
    const storage = { setItem: (key: string, value: string) => { store.set(key, value) } }
    persistUploadJobs(storage, Array.from({ length: 35 }, (_, i) => ({ id: `job-${i}`, status: 'queued' })))
    const restored = restorePersistedJobs(store.get(uploadQueueStorageKey) || null)
    expect(restored).toHaveLength(30)
    expect(restored[0].id).toBe('job-5')
    expect(restored[29].id).toBe('job-34')
  })
})
