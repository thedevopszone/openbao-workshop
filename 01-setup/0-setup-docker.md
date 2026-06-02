# Installation Docker

**Summary**:

Docker ist die Grundlage für die folgenden Kapitel (Single-Node, Cluster, k3d). Hier die schnelle Installation der Docker-Engine inkl. Compose-Plugin auf einem Linux-Host und das Einrichten der Gruppenrechte, damit `docker` ohne `sudo` läuft.

---

## Installation (Linux)

Das offizielle Convenience-Skript installiert Docker-Engine **und** das Compose-Plugin:

```bash
curl -fsSL https://get.docker.com | sudo sh

# eigenen User in die docker-Gruppe aufnehmen (sonst braucht jeder Aufruf sudo)
sudo usermod -aG docker $USER

# Gruppenmitgliedschaft in der aktuellen Shell aktivieren
newgrp docker
```

> `newgrp docker` wirkt nur in der aktuellen Shell. Damit die Gruppenrechte **dauerhaft** und überall greifen, einmal **ab- und wieder anmelden** (bzw. die VM neu starten).

## Prüfen

```bash
docker version              # Client + Server (Engine) erreichbar?
docker compose version      # Compose-Plugin vorhanden?
docker run --rm hello-world # End-to-End-Test
```

Laufen alle drei ohne `sudo` und ohne Fehler, ist Docker bereit für [`1-docker-single-node.md`](1-docker-single-node.md).

> **macOS/Windows:** Dort statt des Skripts **Docker Desktop** installieren (enthält Engine + Compose). Für k3d in Kapitel 3 reicht auf macOS auch `colima` als schlanke Runtime (siehe `3-kubernetes.md`, Teil 0).
