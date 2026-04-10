# OpenWrt Zsh 配置

# 1. 历史记录
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt append_history inc_append_history share_history hist_ignore_all_dups

# 2. Zsh补全
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select

# 3. 主题
autoload -U colors && colors
export DEVICE_NAME="%F{red}💻OpenWrt%f"
PROMPT='${DEVICE_NAME} %(?:%{$fg_bold[green]%}➜ :%{$fg_bold[red]%}➜ ) %{$fg[cyan]%}%c%{$reset_color%} '

# 4. 别名
alias ls='eza --icons=auto'
alias ll='eza -lh --icons=auto --git'
alias tree='eza -T --icons=auto'
alias cat='bat --style=plain'

alias c='clear'

# 5. 加载插件
# 加载历史命令提示
source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
# 命令高亮
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
