#include <rime_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static RimeApi *api;

static void print_context(RimeSessionId session, const char *label) {
  RIME_STRUCT(RimeContext, ctx);
  if (!api->get_context(session, &ctx)) {
    printf("[%s] <no context>\n", label);
    return;
  }
  printf("[%s] preedit=[%s] composing=%d candidates=%d\n", label,
         ctx.composition.preedit ? ctx.composition.preedit : "",
         ctx.composition.length > 0, ctx.menu.num_candidates);
  for (int i = 0; i < ctx.menu.num_candidates; i++) {
    printf("  %2d. %-24s | %s\n", i + 1,
           ctx.menu.candidates[i].text ? ctx.menu.candidates[i].text : "",
           ctx.menu.candidates[i].comment ? ctx.menu.candidates[i].comment : "");
  }
  api->free_context(&ctx);
}

int main(int argc, char **argv) {
  const char *schema = argc > 1 ? argv[1] : "rime_ice";
  const char *keys = argc > 2 ? argv[2] : "nihao";
  int delay_ms = argc > 3 ? atoi(argv[3]) : 0;
  const char *userdir = getenv("RIME_USER_DIR");
  static char fallback[4096];
  if (!userdir) {
    const char *home = getenv("HOME");
    snprintf(fallback, sizeof(fallback), "%s/.local/share/fcitx5/rime",
             home ? home : ".");
    userdir = fallback;
  }

  api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = "/usr/share/rime-data";
  traits.user_data_dir = userdir;
  traits.distribution_name = "Rime";
  traits.distribution_code_name = "rime.cloud.test";
  traits.distribution_version = "0.1";
  traits.app_name = "rime.cloud.test";
  traits.log_dir = "/tmp";
  api->setup(&traits);
  api->initialize(&traits);
  if (api->start_maintenance(False)) api->join_maintenance_thread();

  RimeSessionId session = api->create_session();
  if (!session) { fprintf(stderr, "failed to create session\n"); return 1; }
  if (!api->select_schema(session, schema)) {
    fprintf(stderr, "failed to select schema %s\n", schema);
  }
  printf("schema selected, version=%s\n", api->get_version());

  for (const char *p = keys; *p; p++) {
    int ch = (unsigned char)*p;
    if (ch == ' ') api->process_key(session, 0x20, 0);
    else if (ch == '|') api->process_key(session, 't', 1 << 2); /* Control+t */
    else if (ch == '\n') continue;
    else api->process_key(session, ch, 0);
    if (delay_ms > 0) {
      struct timespec req = { delay_ms / 1000, (delay_ms % 1000) * 1000000L };
      nanosleep(&req, NULL);
    }
  }
  print_context(session, "after keys");

  RIME_STRUCT(RimeCommit, commit);
  if (api->get_commit(session, &commit)) {
    printf("commit=[%s]\n", commit.text ? commit.text : "");
    api->free_commit(&commit);
  }
  api->destroy_session(session);
  api->finalize();
  return 0;
}
