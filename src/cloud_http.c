/*
 * cloud_http.c -- tiny HTTP client for the rime-cloud Lua plugin.
 *
 * Design notes
 * ------------
 * librime-lua runs all Lua code on the input-method thread, but exposes the
 * standard Lua libraries (including io.popen).  Spawning curl for every
 * keystroke is both slow and impossible to keep alive, so this module keeps a
 * persistent libcurl easy handle (connection + DNS cache reuse) and a single
 * worker thread for asynchronous prefetching.
 *
 * Lua API
 * -------
 *   local http = require("cloud_input.cloud_http")
 *   body, code = http.request{url=..., method="GET"|"POST", body=...,
 *                             headers={"A: b"}, resolve={"h:80:1.2.3.4"},
 *                             timeout_ms=800, doh_url=..., max_size=...}
 *   state = http.submit(key, opts)   -- 1 queued, 0 pending/ready, -1 error
 *   body, code = http.poll(key)      -- nil while pending, false,err on error
 *   body, code = http.wait(key, ms)  -- wait for an async request
 *   http.clear(key)                  -- drop a finished result
 *   http.stats()
 *
 * The module never touches librime or the Lua state from the worker thread.
 * Results are handed over through a mutex-protected table.
 */

#define _GNU_SOURCE

#include <curl/curl.h>
#include <lauxlib.h>
#include <lua.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DEFAULT_TIMEOUT_MS 800L
#define MAX_TIMEOUT_MS 15000L
#define DEFAULT_MAX_SIZE (256 * 1024)
#define MAX_QUEUE 16
/* Lanes keep provider connections sticky: lane 0 = Baidu, lane 1 = Sogou.
 * One persistent libcurl handle per lane means TLS/DNS/HTTP keep-alive is
 * reused for every query of that provider, which is what makes the first
 * candidate page fast. */
#define LANE_COUNT 2
#define RESULT_BUCKETS 127
#define RESULT_GC_AGE 300 /* seconds */

typedef struct {
  char *key;
  char *url;
  char *method;
  char *body;
  size_t body_len;
  char *doh_url;
  char **headers;
  size_t header_count;
  char **resolve;
  size_t resolve_count;
  long timeout_ms;
  long max_size;
} request_t;

typedef struct result_t {
  char *key;
  char *body;
  size_t body_len;
  long code;
  int ok;
  char error[CURL_ERROR_SIZE];
  int done;
  volatile int cancelled;
  time_t finished_at;
  struct result_t *next;
} result_t;

typedef struct job_t {
  request_t req;
  result_t *res;
  int lane;
  struct job_t *next;
} job_t;

typedef struct {
  job_t *head;
  job_t *tail;
  size_t len;
} lane_t;

typedef struct {
  char *data;
  size_t len;
  size_t cap;
  int overflow;
  volatile int *cancelled;
} write_buffer_t;

static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static pthread_t g_workers[LANE_COUNT];
static int g_worker_started = 0;
static int g_worker_count = 0;
static int g_stop = 0;

static lane_t g_lanes[LANE_COUNT];

static result_t *g_results[RESULT_BUCKETS];
static size_t g_result_count = 0;

static CURL *g_sync_curl = NULL;
static int g_curl_global = 0;

/* ------------------------------------------------------------------ */
/* small helpers                                                       */
/* ------------------------------------------------------------------ */

static void request_free(request_t *r) {
  free(r->key);
  free(r->url);
  free(r->method);
  free(r->body);
  free(r->doh_url);
  for (size_t i = 0; i < r->header_count; ++i)
    free(r->headers[i]);
  free(r->headers);
  for (size_t i = 0; i < r->resolve_count; ++i)
    free(r->resolve[i]);
  free(r->resolve);
  memset(r, 0, sizeof(*r));
}

static char *xstrdup(const char *s) {
  if (!s)
    return NULL;
  char *p = strdup(s);
  if (!p) {
    fprintf(stderr, "[rime-cloud] out of memory\n");
    abort();
  }
  return p;
}

static unsigned int key_hash(const char *s) {
  unsigned int h = 2166136261u;
  while (*s) {
    h ^= (unsigned char)*s++;
    h *= 16777619u;
  }
  return h % RESULT_BUCKETS;
}

static result_t *result_find_locked(const char *key) {
  for (result_t *r = g_results[key_hash(key)]; r; r = r->next) {
    if (strcmp(r->key, key) == 0)
      return r;
  }
  return NULL;
}

static void result_unlink_locked(result_t *target) {
  unsigned int h = key_hash(target->key);
  result_t **p = &g_results[h];
  while (*p) {
    if (*p == target) {
      *p = target->next;
      g_result_count--;
      return;
    }
    p = &(*p)->next;
  }
}

static void result_free(result_t *r) {
  if (!r)
    return;
  free(r->key);
  free(r->body);
  free(r);
}

static void results_gc_locked(void) {
  time_t now = time(NULL);
  for (int i = 0; i < RESULT_BUCKETS; ++i) {
    result_t **p = &g_results[i];
    while (*p) {
      result_t *r = *p;
      if (r->done && now - r->finished_at > RESULT_GC_AGE) {
        *p = r->next;
        g_result_count--;
        result_free(r);
      } else {
        p = &r->next;
      }
    }
  }
}

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  write_buffer_t *b = (write_buffer_t *)userdata;
  size_t n = size * nmemb;
  if (b->overflow || (b->cancelled && *b->cancelled))
    return 0;
  if (b->len + n > b->cap) {
    b->overflow = 1;
    return 0;
  }
  memcpy(b->data + b->len, ptr, n);
  b->len += n;
  return n;
}

static void setopt_long(CURL *h, CURLoption opt, long v) {
  (void)curl_easy_setopt(h, opt, v);
}

/* Build a curl_slist; the caller must free it. */
static struct curl_slist *build_slist(char **items, size_t count) {
  struct curl_slist *list = NULL;
  for (size_t i = 0; i < count; ++i) {
    struct curl_slist *next = curl_slist_append(list, items[i]);
    if (!next) {
      curl_slist_free_all(list);
      return NULL;
    }
    list = next;
  }
  return list;
}

/* ------------------------------------------------------------------ */
/* HTTP core                                                           */
/* ------------------------------------------------------------------ */

typedef struct {
  char *body;
  size_t body_len;
  long code;
  int ok;
  char error[CURL_ERROR_SIZE];
} http_response_t;

static void http_response_free(http_response_t *r) {
  free(r->body);
  r->body = NULL;
  r->body_len = 0;
}

/*
 * Perform one request with `h`.  Returns 0 on a transport-level error, 1 when
 * a response (any HTTP status) was received.
 */
static int progress_cb(void *clientp, curl_off_t dltotal, curl_off_t dlnow,
                       curl_off_t ultotal, curl_off_t ulnow) {
  (void)dltotal;
  (void)dlnow;
  (void)ultotal;
  (void)ulnow;
  volatile int *cancelled = (volatile int *)clientp;
  return (cancelled && *cancelled) ? 1 : 0;
}

static int http_perform(CURL *h, const request_t *req, http_response_t *out,
                        volatile int *cancelled) {
  memset(out, 0, sizeof(*out));
  curl_easy_reset(h);

  write_buffer_t buf;
  buf.cap = (req->max_size > 0) ? (size_t)req->max_size : DEFAULT_MAX_SIZE;
  buf.len = 0;
  buf.overflow = 0;
  buf.cancelled = cancelled;
  buf.data = malloc(buf.cap + 1);
  if (!buf.data) {
    snprintf(out->error, sizeof(out->error), "out of memory");
    return 0;
  }

  struct curl_slist *headers = build_slist(req->headers, req->header_count);
  struct curl_slist *resolve = build_slist(req->resolve, req->resolve_count);

  curl_easy_setopt(h, CURLOPT_URL, req->url);
  curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(h, CURLOPT_WRITEDATA, &buf);
  curl_easy_setopt(h, CURLOPT_ERRORBUFFER, out->error);
  setopt_long(h, CURLOPT_NOSIGNAL, 1L);
  setopt_long(h, CURLOPT_TCP_KEEPALIVE, 1L);
  setopt_long(h, CURLOPT_NOPROGRESS, 0L);
  curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, progress_cb);
  curl_easy_setopt(h, CURLOPT_XFERINFODATA, cancelled);
  curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, "");
  setopt_long(h, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(h, CURLOPT_USERAGENT,
                   "rime-cloud/0.1 (fcitx5-rime cloud input plugin)");
  setopt_long(h, CURLOPT_CONNECTTIMEOUT_MS,
              req->timeout_ms < 500 ? req->timeout_ms : 500L);
  setopt_long(h, CURLOPT_TIMEOUT_MS, req->timeout_ms);
  setopt_long(h, CURLOPT_DNS_CACHE_TIMEOUT, 600L);
  setopt_long(h, CURLOPT_SSL_VERIFYPEER, 1L);
  setopt_long(h, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(h, CURLOPT_PROTOCOLS_STR, "http,https");

  if (headers)
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, headers);
  if (resolve)
    curl_easy_setopt(h, CURLOPT_RESOLVE, resolve);
  if (req->doh_url && req->doh_url[0])
    curl_easy_setopt(h, CURLOPT_DOH_URL, req->doh_url);

  if (req->method && strcmp(req->method, "POST") == 0) {
    setopt_long(h, CURLOPT_POST, 1L);
    curl_easy_setopt(h, CURLOPT_POSTFIELDS, req->body ? req->body : "");
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE,
                     (curl_off_t)(req->body ? req->body_len : 0));
  } else if (req->method && strcmp(req->method, "HEAD") == 0) {
    setopt_long(h, CURLOPT_NOBODY, 1L);
  } else {
    setopt_long(h, CURLOPT_HTTPGET, 1L);
  }

  CURLcode rc = curl_easy_perform(h);

  curl_slist_free_all(headers);
  curl_slist_free_all(resolve);

  if (rc != CURLE_OK) {
    if (out->error[0] == '\0')
      snprintf(out->error, sizeof(out->error), "%s", curl_easy_strerror(rc));
    free(buf.data);
    return 0;
  }

  long code = 0;
  curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
  out->code = code;
  buf.data[buf.len] = '\0';
  out->body = buf.data;
  out->body_len = buf.len;
  out->ok = 1;
  return 1;
}

/* ------------------------------------------------------------------ */
/* worker                                                              */
/* ------------------------------------------------------------------ */

static void result_publish_locked(result_t *res, const http_response_t *resp) {
  res->ok = resp->ok;
  res->code = resp->code;
  if (resp->body) {
    res->body = resp->body; /* transfer ownership */
    res->body_len = resp->body_len;
  }
  if (!resp->ok)
    snprintf(res->error, sizeof(res->error), "%s",
             resp->error[0] ? resp->error : "request failed");
  res->done = 1;
  res->finished_at = time(NULL);
}

static void *worker_main(void *arg) {
  int lane = (int)(intptr_t)arg;
  lane_t *q = &g_lanes[lane];
  CURL *curl = curl_easy_init();
  if (!curl)
    return NULL;

  for (;;) {
    pthread_mutex_lock(&g_mutex);
    while (!q->head && !g_stop)
      pthread_cond_wait(&g_cond, &g_mutex);
    if (!q->head) {
      pthread_mutex_unlock(&g_mutex);
      break;
    }
    job_t *job = q->head;
    q->head = job->next;
    if (!q->head)
      q->tail = NULL;
    q->len--;
    pthread_mutex_unlock(&g_mutex);

    http_response_t resp;
    int ok = http_perform(curl, &job->req, &resp,
                          job->res ? &job->res->cancelled : NULL);

    result_t *doomed = NULL;
    pthread_mutex_lock(&g_mutex);
    result_t *res = result_find_locked(job->req.key);
    if (res && res->cancelled) {
      result_unlink_locked(res);
      doomed = res;
      if (resp.body) {
        free(resp.body);
        resp.body = NULL;
      }
    } else if (res && !res->done) {
      result_publish_locked(res, &resp);
    } else if (resp.body) {
      free(resp.body);
    }
    pthread_cond_broadcast(&g_cond);
    pthread_mutex_unlock(&g_mutex);

    result_free(doomed);
    (void)ok;
    request_free(&job->req);
    free(job);
  }
  curl_easy_cleanup(curl);
  return NULL;
}

static void start_worker(void) {
  pthread_mutex_lock(&g_mutex);
  if (!g_worker_started) {
    g_stop = 0;
    g_worker_count = 0;
    for (int i = 0; i < LANE_COUNT; ++i) {
      if (pthread_create(&g_workers[g_worker_count], NULL, worker_main,
                         (void *)(intptr_t)i) == 0)
        g_worker_count++;
    }
    g_worker_started = g_worker_count > 0;
  }
  pthread_mutex_unlock(&g_mutex);
}

/* Stop all workers.  Called from Lua component fini before the Lua state (and
 * this shared object) is unloaded; otherwise Lua's dlclose could pull the
 * module out from under a running curl request. */
static void stop_workers(void) {
  pthread_mutex_lock(&g_mutex);
  int any = g_worker_started;
  for (int i = 0; i < LANE_COUNT; ++i)
    if (g_lanes[i].head) any = 1;
  if (!any) {
    pthread_mutex_unlock(&g_mutex);
    return;
  }
  g_stop = 1;

  /* Ask in-flight requests to abort. */
  for (int i = 0; i < RESULT_BUCKETS; ++i) {
    for (result_t *r = g_results[i]; r; r = r->next)
      r->cancelled = 1;
  }

  /* Detach all queued jobs from every lane. */
  job_t *jobs = NULL;
  job_t **tail = &jobs;
  for (int i = 0; i < LANE_COUNT; ++i) {
    if (g_lanes[i].head) {
      *tail = g_lanes[i].head;
      while (*tail) tail = &(*tail)->next;
    }
    g_lanes[i].head = g_lanes[i].tail = NULL;
    g_lanes[i].len = 0;
  }
  pthread_cond_broadcast(&g_cond);
  pthread_mutex_unlock(&g_mutex);

  while (jobs) {
    job_t *next = jobs->next;
    result_t *r = NULL;
    pthread_mutex_lock(&g_mutex);
    r = result_find_locked(jobs->req.key);
    if (r) result_unlink_locked(r);
    pthread_mutex_unlock(&g_mutex);
    result_free(r);
    request_free(&jobs->req);
    free(jobs);
    jobs = next;
  }

  for (int i = 0; i < g_worker_count; ++i)
    pthread_join(g_workers[i], NULL);

  pthread_mutex_lock(&g_mutex);
  g_worker_started = 0;
  g_worker_count = 0;
  g_stop = 0;
  pthread_mutex_unlock(&g_mutex);
}

static void ensure_curl(void) {
  if (!g_curl_global) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    g_curl_global = 1;
  }
}

/* ------------------------------------------------------------------ */
/* Lua <-> request                                                     */
/* ------------------------------------------------------------------ */

static char **read_string_array(lua_State *L, int idx, size_t *count) {
  *count = 0;
  if (!lua_istable(L, idx))
    return NULL;
  lua_Integer n = luaL_len(L, idx);
  if (n <= 0)
    return NULL;
  char **items = calloc((size_t)n, sizeof(char *));
  if (!items)
    return NULL;
  for (lua_Integer i = 1; i <= n; ++i) {
    lua_rawgeti(L, idx, i);
    size_t len = 0;
    const char *s = lua_tolstring(L, -1, &len);
    if (s && len > 0)
      items[*count] = xstrdup(s);
    lua_pop(L, 1);
    if (items[*count])
      (*count)++;
  }
  return items;
}

static void parse_request(lua_State *L, int idx, request_t *req) {
  memset(req, 0, sizeof(*req));
  if (!lua_istable(L, idx))
    luaL_error(L, "options table expected");

  lua_getfield(L, idx, "url");
  const char *url = luaL_checkstring(L, -1);
  req->url = xstrdup(url);
  lua_pop(L, 1);

  lua_getfield(L, idx, "method");
  if (!lua_isnil(L, -1)) {
    const char *m = luaL_checkstring(L, -1);
    req->method = xstrdup(m);
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "body");
  if (!lua_isnil(L, -1)) {
    size_t len = 0;
    const char *body = luaL_checklstring(L, -1, &len);
    req->body = malloc(len + 1);
    if (!req->body)
      luaL_error(L, "out of memory");
    memcpy(req->body, body, len);
    req->body[len] = '\0';
    req->body_len = len;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "timeout_ms");
  if (!lua_isnil(L, -1)) {
    lua_Integer t = luaL_checkinteger(L, -1);
    if (t < 50)
      t = 50;
    if (t > MAX_TIMEOUT_MS)
      t = MAX_TIMEOUT_MS;
    req->timeout_ms = (long)t;
  } else {
    req->timeout_ms = DEFAULT_TIMEOUT_MS;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "max_size");
  if (!lua_isnil(L, -1)) {
    lua_Integer m = luaL_checkinteger(L, -1);
    if (m < 256)
      m = 256;
    if (m > 4 * 1024 * 1024)
      m = 4 * 1024 * 1024;
    req->max_size = (long)m;
  } else {
    req->max_size = DEFAULT_MAX_SIZE;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "doh_url");
  if (!lua_isnil(L, -1))
    req->doh_url = xstrdup(luaL_checkstring(L, -1));
  lua_pop(L, 1);

  lua_getfield(L, idx, "headers");
  req->headers = read_string_array(L, lua_gettop(L), &req->header_count);
  lua_pop(L, 1);

  lua_getfield(L, idx, "resolve");
  req->resolve = read_string_array(L, lua_gettop(L), &req->resolve_count);
  lua_pop(L, 1);
}

static void push_result(lua_State *L, const result_t *res) {
  if (res->ok) {
    lua_pushlstring(L, res->body ? res->body : "", res->body_len);
    lua_pushinteger(L, res->code);
  } else {
    lua_pushnil(L);
    lua_pushstring(L, res->error);
  }
}

static int l_request(lua_State *L) {
  ensure_curl();
  request_t req;
  parse_request(L, 1, &req);

  pthread_mutex_lock(&g_mutex);
  if (!g_sync_curl)
    g_sync_curl = curl_easy_init();
  CURL *curl = g_sync_curl;
  pthread_mutex_unlock(&g_mutex);

  if (!curl) {
    request_free(&req);
    return luaL_error(L, "curl_easy_init failed");
  }

  http_response_t resp;
  int ok = http_perform(curl, &req, &resp, NULL);
  request_free(&req);

  if (!ok) {
    lua_pushnil(L);
    lua_pushstring(L, resp.error);
    return 2;
  }
  lua_pushlstring(L, resp.body ? resp.body : "", resp.body_len);
  lua_pushinteger(L, resp.code);
  http_response_free(&resp);
  return 2;
}

static int request_lane(lua_State *L, int idx) {
  int lane = 0;
  if (lua_istable(L, idx)) {
    lua_getfield(L, idx, "lane");
    if (!lua_isnil(L, -1))
      lane = (int)luaL_checkinteger(L, -1);
    lua_pop(L, 1);
  }
  if (lane < 0 || lane >= LANE_COUNT)
    lane = 0;
  return lane;
}

static int l_submit(lua_State *L) {
  ensure_curl();
  const char *key = luaL_checkstring(L, 1);
  if (strlen(key) > 512)
    return luaL_error(L, "key too long");
  luaL_checktype(L, 2, LUA_TTABLE);

  request_t req;
  parse_request(L, 2, &req);
  int lane = request_lane(L, 2);
  start_worker();

  pthread_mutex_lock(&g_mutex);
  result_t *existing = result_find_locked(key);
  if (existing) {
    int done = existing->done;
    pthread_mutex_unlock(&g_mutex);
    request_free(&req);
    lua_pushinteger(L, 0);
    (void)done;
    return 1;
  }
  if (g_lanes[lane].len >= MAX_QUEUE) {
    pthread_mutex_unlock(&g_mutex);
    request_free(&req);
    lua_pushinteger(L, -1);
    return 1;
  }

  result_t *res = calloc(1, sizeof(*res));
  job_t *job = calloc(1, sizeof(*job));
  if (!res || !job) {
    free(res);
    free(job);
    pthread_mutex_unlock(&g_mutex);
    request_free(&req);
    lua_pushinteger(L, -1);
    return 1;
  }
  res->key = xstrdup(key);
  unsigned int h = key_hash(key);
  res->next = g_results[h];
  g_results[h] = res;
  g_result_count++;

  if (!req.key)
    req.key = xstrdup(key);
  job->req = req;
  job->res = res;
  job->lane = lane;

  lane_t *q = &g_lanes[lane];
  if (q->tail)
    q->tail->next = job;
  else
    q->head = job;
  q->tail = job;
  q->len++;
  /* Wake both lanes: a single signal could wake the wrong worker. */
  pthread_cond_broadcast(&g_cond);
  pthread_mutex_unlock(&g_mutex);

  lua_pushinteger(L, 1);
  return 1;
}

/* expects g_mutex held; unlinks and returns the result */
static result_t *take_result_locked(const char *key) {
  result_t *res = result_find_locked(key);
  if (!res || !res->done)
    return NULL;
  result_unlink_locked(res);
  return res;
}

static int l_poll(lua_State *L) {
  const char *key = luaL_checkstring(L, 1);
  pthread_mutex_lock(&g_mutex);
  result_t *res = take_result_locked(key);
  if (!res) {
    pthread_mutex_unlock(&g_mutex);
    lua_pushnil(L);
    return 1;
  }
  push_result(L, res);
  pthread_mutex_unlock(&g_mutex);
  result_free(res);
  return 2;
}

static int l_wait(lua_State *L) {
  const char *key = luaL_checkstring(L, 1);
  lua_Integer ms = luaL_optinteger(L, 2, 1000);
  if (ms < 0)
    ms = 0;

  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += (time_t)(ms / 1000);
  deadline.tv_nsec += (long)(ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec++;
    deadline.tv_nsec -= 1000000000L;
  }

  pthread_mutex_lock(&g_mutex);
  result_t *res = NULL;
  for (;;) {
    res = take_result_locked(key);
    if (res)
      break;
    if (ms == 0)
      break;
    int rc = pthread_cond_timedwait(&g_cond, &g_mutex, &deadline);
    if (rc != 0)
      break;
  }
  if (!res) {
    pthread_mutex_unlock(&g_mutex);
    lua_pushnil(L);
    return 1;
  }
  push_result(L, res);
  pthread_mutex_unlock(&g_mutex);
  result_free(res);
  return 2;
}

static int l_cancel(lua_State *L) {
  const char *key = luaL_checkstring(L, 1);

  pthread_mutex_lock(&g_mutex);

  /* If the job has not started yet, remove it from its lane queue. */
  job_t *removed_job = NULL;
  for (int lane = 0; lane < LANE_COUNT && !removed_job; ++lane) {
    lane_t *q = &g_lanes[lane];
    job_t *prev = NULL;
    job_t **pp = &q->head;
    while (*pp) {
      if (strcmp((*pp)->req.key, key) == 0) {
        removed_job = *pp;
        *pp = removed_job->next;
        if (q->tail == removed_job)
          q->tail = prev;
        q->len--;
        break;
      }
      prev = *pp;
      pp = &(*pp)->next;
    }
  }

  result_t *doomed = NULL;
  result_t *res = result_find_locked(key);
  if (removed_job) {
    if (res) {
      result_unlink_locked(res);
      doomed = res;
    }
  } else if (res) {
    if (res->done) {
      result_unlink_locked(res);
      doomed = res;
    } else {
      /* Running: ask the worker to abort at the next callback. */
      res->cancelled = 1;
    }
  }
  pthread_mutex_unlock(&g_mutex);

  if (removed_job) {
    request_free(&removed_job->req);
    free(removed_job);
  }
  result_free(doomed);
  lua_pushboolean(L, removed_job != NULL || doomed != NULL);
  return 1;
}

static int l_wait_any(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer count = luaL_len(L, 1);
  lua_Integer ms = luaL_optinteger(L, 2, 1000);
  if (count <= 0) {
    lua_pushnil(L);
    return 1;
  }
  if (ms < 0)
    ms = 0;

  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += (time_t)(ms / 1000);
  deadline.tv_nsec += (long)(ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec++;
    deadline.tv_nsec -= 1000000000L;
  }

  pthread_mutex_lock(&g_mutex);
  result_t *found = NULL;
  const char *found_key = NULL;
  for (;;) {
    for (lua_Integer i = 1; i <= count; ++i) {
      lua_rawgeti(L, 1, i);
      const char *key = lua_tostring(L, -1);
      lua_pop(L, 1);
      if (!key)
        continue;
      result_t *res = result_find_locked(key);
      if (res && res->done) {
        found = res;
        found_key = key;
        break;
      }
    }
    if (found)
      break;
    if (ms == 0)
      break;
    int rc = pthread_cond_timedwait(&g_cond, &g_mutex, &deadline);
    if (rc != 0)
      break;
  }

  if (!found) {
    pthread_mutex_unlock(&g_mutex);
    lua_pushnil(L);
    return 1;
  }

  lua_pushstring(L, found_key);
  if (found->ok) {
    lua_pushlstring(L, found->body ? found->body : "", found->body_len);
    lua_pushinteger(L, found->code);
  } else {
    lua_pushnil(L);
    lua_pushstring(L, found->error);
  }
  result_unlink_locked(found);
  pthread_mutex_unlock(&g_mutex);
  result_free(found);
  return 3;
}

static int l_clear(lua_State *L) {
  const char *key = luaL_checkstring(L, 1);
  pthread_mutex_lock(&g_mutex);
  result_t *res = take_result_locked(key);
  /* A finished result can also be removed if done; pending stays. */
  if (res) {
    pthread_mutex_unlock(&g_mutex);
    result_free(res);
    lua_pushboolean(L, 1);
    return 1;
  }
  pthread_mutex_unlock(&g_mutex);
  lua_pushboolean(L, 0);
  return 1;
}

static int l_now_ms(lua_State *L) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  lua_pushinteger(L, (lua_Integer)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
  return 1;
}

static int l_stats(lua_State *L) {
  pthread_mutex_lock(&g_mutex);
  results_gc_locked();
  size_t total = 0;
  for (int i = 0; i < LANE_COUNT; ++i)
    total += g_lanes[i].len;
  lua_newtable(L);
  lua_pushinteger(L, (lua_Integer)total);
  lua_setfield(L, -2, "queue");
  lua_newtable(L);
  for (int i = 0; i < LANE_COUNT; ++i) {
    lua_pushinteger(L, (lua_Integer)g_lanes[i].len);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "lanes");
  lua_pushinteger(L, (lua_Integer)g_result_count);
  lua_setfield(L, -2, "results");
  lua_pushboolean(L, g_worker_started);
  lua_setfield(L, -2, "worker");
  pthread_mutex_unlock(&g_mutex);
  return 1;
}

static int l_shutdown(lua_State *L) {
  stop_workers();
  lua_pushboolean(L, 1);
  return 1;
}

/* Safety net for clients that do not call cloud_input/translator/fini. */
__attribute__((destructor)) static void module_unload(void) {
  stop_workers();
}

int luaopen_cloud_http(lua_State *L) {
  ensure_curl();
  lua_newtable(L);

  lua_pushcfunction(L, l_request);
  lua_setfield(L, -2, "request");
  lua_pushcfunction(L, l_submit);
  lua_setfield(L, -2, "submit");
  lua_pushcfunction(L, l_poll);
  lua_setfield(L, -2, "poll");
  lua_pushcfunction(L, l_wait);
  lua_setfield(L, -2, "wait");
  lua_pushcfunction(L, l_wait_any);
  lua_setfield(L, -2, "wait_any");
  lua_pushcfunction(L, l_clear);
  lua_setfield(L, -2, "clear");
  lua_pushcfunction(L, l_cancel);
  lua_setfield(L, -2, "cancel");
  lua_pushcfunction(L, l_stats);
  lua_setfield(L, -2, "stats");
  lua_pushcfunction(L, l_now_ms);
  lua_setfield(L, -2, "now_ms");
  lua_pushcfunction(L, l_shutdown);
  lua_setfield(L, -2, "shutdown");

  lua_pushstring(L, "0.1.0");
  lua_setfield(L, -2, "version");
  lua_pushstring(L, curl_version());
  lua_setfield(L, -2, "curl_version");

  return 1;
}

/* Lua 5.5 derives the entry point from the full module name:
 * require("cloud_input.cloud_http") -> luaopen_cloud_input_cloud_http. */
int luaopen_cloud_input_cloud_http(lua_State *L) {
  return luaopen_cloud_http(L);
}
