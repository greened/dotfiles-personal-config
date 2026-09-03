# Home/personal window layout: one window per project I work at home.
#
# Selected by tmux/pick-layout.sh in the work overlay, which runs from the
# `after-new-session' hook: a session named `home' gets this, and so does any
# machine not in that script's WORK_HOSTS allowlist.  `tmux new -s work' forces
# the work set instead.
#
# mirv, dartt and freebook are greened GitHub repos not cloned on the work
# machines, so those windows will start in $HOME there rather than in the project.
# The six shared with the work set -- quite, prevue-gaffer, gazette, dotfiles,
# watch-queue, skills-sync -- keep the same names in both contexts deliberately,
# so a window name means the same project whichever set built it.
#
# prevue-gaffer is one window because the pair is worked together, which is also
# why memory-personal/SLUGS.map gives either project's slug both memories.
rename-window -t 0 mirv
new-window -d -n dartt
new-window -d -n freebook
new-window -d -n quite
new-window -d -n prevue-gaffer
new-window -d -n gazette
new-window -d -n dotfiles
new-window -d -n watch-queue
new-window -d -n skills-sync
