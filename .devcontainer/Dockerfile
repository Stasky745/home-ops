FROM mcr.microsoft.com/devcontainers/base:alpine-3.21

# Install Nix (Determinate Systems installer works well in containers)
RUN curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install linux \
    --no-confirm \
    --init none \
    --extra-conf "sandbox = false" \
    --extra-conf "experimental-features = nix-command flakes"

ENV PATH="/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# Write nix paths into a profile.d script so all shell types pick them up
RUN echo 'export PATH="/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"' \
    > /etc/profile.d/nix.sh

# Install direnv and go-task at image build time
RUN nix profile install nixpkgs#direnv nixpkgs#go-task

# Enable direnv hook for interactive shells
RUN echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc \
    && echo 'eval "$(direnv hook zsh)"' >> /etc/zsh/zshrc
