{application, gen_cluster,
 [
  {description, "Gen cluster"},
  {vsn, "0.1"},
  {id, "gen_cluster"},
  {modules,      [
                    gen_cluster,
                    reloader
                ]},
  {registered,   []},
  {applications, [kernel, stdlib]},
  {mod, {gen_cluster, []}},
  {env, []}
 ]
}.