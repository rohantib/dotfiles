# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Tilix VTE setup
if [ $TILIX_ID ] || [ $VTE_VERSION ]; then
        source /etc/profile.d/vte.sh
fi

# Add local executables to PATH
export PATH=$PATH:/home/rohan/User_Software/bin

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Load antigen
source /usr/share/zsh/share/antigen.zsh

# Load Antigen configurations
antigen init ~/.antigenrc

# Direnv ZSH hook
eval "$(direnv hook zsh)"

# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/home/rohan/miniconda3/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/home/rohan/miniconda3/etc/profile.d/conda.sh" ]; then
        . "/home/rohan/miniconda3/etc/profile.d/conda.sh"
    else
        export PATH="/home/rohan/miniconda3/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<

# C++ shortcuts for CP
co() { g++ -std=c++17 -O2 -o "${1%.*}" $1 -Wall -Wshadow -ggdb -fsanitize=address,undefined; }
run() { co $1 && ./${1%.*}; }

co_dbg() { g++ -std=c++17 -O2 -o "${1%.*}" $1 -ggdb -Wall -Wextra -pedantic -std=c++11 -O2 -Wshadow -Wformat=2 -Wfloat-equal -Wconversion -Wlogical-op -Wshift-overflow=2 -Wduplicated-cond -Wcast-qual -Wcast-align -D_GLIBCXX_DEBUG -D_GLIBCXX_DEBUG_PEDANTIC -D_FORTIFY_SOURCE=2 -fsanitize=address -fsanitize=undefined -fno-sanitize-recover -fstack-protector; }
run_dbg() { co $1 && ./${1%.*}; }


