#!/usr/bin/env bash
# Leave copy mode on keypress and pass the key through to the pane

chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`~!@#$%^&*()-_=+[]{}|:,.<>"'"'"'\'
named='Space Enter BSpace Tab BTab DC IC F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12'
for c in {a..z}; do named+=" C-$c M-$c"; done

for table in copy-mode copy-mode-vi; do
  for (( i=0; i<${#chars}; i++ )); do
    k="${chars:i:1}"
    tmux bind -T "$table" -- "$k" send-keys -X cancel '\;' send-keys -- "$k"
  done
  for k in $named; do
    tmux bind -T "$table" "$k" send-keys -X cancel '\;' send-keys "$k"
  done
  # Semicolon escaping
  tmux bind -T "$table" '\;' send-keys -X cancel '\;' send-keys '\;'
  # Don't send Escape to shell
  tmux bind -T "$table" Escape send-keys -X cancel
  # Search scrollback
  tmux bind -T "$table" / command-prompt -T search -p '(search down)' 'send-keys -X search-forward -- "%%"'
  tmux bind -T "$table" '?' command-prompt -T search -p '(search up)' 'send-keys -X search-backward -- "%%"'
  # Drop catch-all binding
  tmux unbind -T "$table" Any 2>/dev/null || true
done
