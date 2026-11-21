// havend runs Nostr Vault on a Linux box (the "nostr-vault-linux"
// container): the same vault engine the Mac app runs, one front door on
// NV_PORT for the relay, Blossom, the web app and the owner-only box API.
// The box has one identity, the mesh key nv-mesh makes (mesh/npub); havend
// reports that npub and writes mesh-devices.json from the owner's 10063.
//
// The vault engine is haven-go's relay binary built pure Go with
// `-tags nolmdb` (Badger, as libhaven on the Mac). havend starts it on a
// loopback port with the Mac's settings and restarts it if it dies.
//
// Environment:
//
//	NV_OWNER            owner npub (or hex), set by the installer. Unset: the
//	                    npub in $NV_DATA_DIR/box/owner, which claim mode saves
//	NV_SETUP_CODE       claim mode (no owner yet): only the setup page runs,
//	                    and the npub sent with this code becomes the owner
//	NV_UPDATE_VIA       startos or umbrel: the store updates the box, so POST
//	                    update answers managed
//	NV_DATA_DIR         data dir, default /data
//	NV_PORT             the box's port, default 8080
//	NV_WEB_DIR          built web app; unset = the vault's own page at /
//	NV_ENGINE_BIN       vault engine, default /usr/local/bin/haven-engine
//	NV_ENGINE_PORT      engine's loopback port, default 3355
//	NV_RELAY_URL        the URL the vault calls itself (NIP-42), optional
//	NV_MOVE_ROOT        where POST move may move the vault, default /mnt;
//	                    set but empty: Move is off (a store owns the disk)
//	NV_UPDATE_HOOK      program run on POST update; unset = manual
//	NV_MESH_STATUS_FILE mesh status JSON, default $NV_DATA_DIR/mesh/status.json
//	NV_MESH_DEVICES     owner's devices for nv-mesh, default $NV_DATA_DIR/mesh-devices.json
//	NV_MESH_DOOR_PORT   the engine's loopback mesh door, default NV_PORT+1
//	NV_DIRECTORY_RELAYS comma list, where to look for the owner's 10063
//	NV_BACKUP_PROVIDER  "s3" to turn on backups, with NV_S3_* settings
//
// `havend device` prints the box's npub (the mesh's, from mesh/npub) and
// exits: the npub the owner adds in My Devices. It fails until nv-mesh has
// made the key on its first start.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/barrydeen/haven/internal/box"
)

// version is set at build time: -ldflags "-X main.version=..."
var version = ""

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if err := run(os.Args[1:]); err != nil {
		log.Fatalf("havend: %v", err)
	}
}

// lookupEnv is os.LookupEnv with the build's version as NV_VERSION's default.
func lookupEnv(k string) (string, bool) {
	v, ok := os.LookupEnv(k)
	if k == "NV_VERSION" && v == "" && version != "" {
		return version, true
	}
	return v, ok
}

func run(args []string) error {
	cfg, err := box.ConfigFromLookup(lookupEnv)
	if err != nil {
		return err
	}
	mesh := box.MeshID{NpubFile: cfg.MeshNpubFile}
	if len(args) > 0 {
		switch args[0] {
		case "device":
			npub, _, ok := mesh.Read()
			if !ok {
				return fmt.Errorf("no box npub yet: nv-mesh writes %s on its first start", cfg.MeshNpubFile)
			}
			fmt.Println(npub)
			return nil
		default:
			return fmt.Errorf("unknown command %q (commands: device)", args[0])
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if cfg.Claiming() {
		if err := serveClaim(ctx, cfg); err != nil {
			return err
		}
		if ctx.Err() != nil {
			return nil
		}
		// Claimed: read the settings again, now with box/owner.
		if cfg, err = box.ConfigFromLookup(lookupEnv); err != nil {
			return err
		}
		if cfg.Claiming() {
			return errors.New("claimed, but box/owner did not read back")
		}
	}

	vaultDir := box.LoadVaultDir(cfg.BoxDir(), cfg.DefaultVaultDir())
	// The engine's copy of the paired devices (the set the apps pass in with
	// SetMeshDevicesC): written before the engine starts, then kept in step
	// with mesh-devices.json every 5 s (box/devices_engine.go).
	engineDevices := &box.EngineDevices{
		Mesh: mesh,
		From: cfg.MeshDevicesFile,
		To:   filepath.Join(cfg.BoxDir(), "engine-mesh-devices.json"),
	}
	if _, err := engineDevices.Sync(); err != nil {
		log.Printf("box: engine devices: %v", err)
	}
	engine := &box.Engine{
		Bin: cfg.EngineBin,
		Env: func(dir string) []string {
			return append(box.EngineEnvList(cfg, dir, os.Getenv), "HAVEN_MESH_DEVICES_FILE="+engineDevices.To)
		},
		Prepare: func(dir string) error { return box.WriteEngineFiles(cfg, dir) },
	}
	if err := engine.Start(ctx, vaultDir); err != nil {
		return fmt.Errorf("starting the vault engine: %w", err)
	}

	api := &box.API{
		Auth:       box.NewOwnerAuth(cfg.OwnerHex),
		Version:    cfg.Version,
		Started:    time.Now(),
		Mesh:       mesh,
		Owner:      cfg.OwnerNpub,
		RelayURL:   cfg.RelayURL,
		Engine:     engine,
		MeshStatus: cfg.MeshStatusFile,
		Storage:    &box.StorageMeter{},
		Devices: &box.Devices{
			OwnerHex:    cfg.OwnerHex,
			Mesh:        mesh,
			DevicesFile: cfg.MeshDevicesFile,
			Source: &box.RelayServerLists{
				VaultURL:  "ws://127.0.0.1:" + strconv.Itoa(cfg.EnginePort),
				Directory: cfg.DirectoryRelays,
			},
		},
		Mover: &box.Mover{
			Root:     cfg.MoveRoot,
			BoxDir:   cfg.BoxDir(),
			Engine:   engine,
			Ctx:      ctx,
			FreeOf:   func(p string) (uint64, error) { d, err := box.DiskOf(p); return d.Free, err },
			Headroom: 256 << 20,
		},
		Updater: &box.Updater{Hook: cfg.UpdateHook, BoxDir: cfg.BoxDir(), Store: cfg.UpdateVia},
	}
	// The owner's 10063 decides which devices nv-mesh lets in: read it now
	// and every 30 s, so an approval or a removal reaches the mesh by itself.
	// Each read asks the vault; the directory relays only every 10 minutes,
	// when the vault has no list, or while theirs is newer than the vault's
	// (box.RelayServerLists.Poll).
	go api.Devices.Run(ctx, 30*time.Second)
	go engineDevices.Run(ctx, 5*time.Second)

	front := &box.Front{API: api, Engine: box.EngineProxy(cfg.EnginePort)}
	if cfg.WebDir != "" {
		front.Web = box.WebApp(cfg.WebDir)
	}

	srv := &http.Server{
		Addr:              net.JoinHostPort("", strconv.Itoa(cfg.Port)),
		Handler:           front,
		ReadHeaderTimeout: 15 * time.Second,
	}
	boxNpub, _, ok := mesh.Read()
	if !ok {
		boxNpub = "(not yet: nv-mesh makes it)"
	}
	log.Printf("havend %s: owner %s, box %s, vault %s, listening on :%d, mesh door on 127.0.0.1:%d",
		cfg.Version, cfg.OwnerNpub, boxNpub, vaultDir, cfg.Port, cfg.MeshDoorPort)

	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	select {
	case err := <-errc:
		engine.Stop()
		return err
	case <-ctx.Done():
	}
	log.Println("havend: stopping")
	shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutCtx); err != nil && !errors.Is(err, context.DeadlineExceeded) {
		log.Printf("havend: shutdown: %v", err)
	}
	engine.Stop()
	return nil
}

// serveClaim runs claim mode on NV_PORT until the box is claimed or stopped:
// only the setup page, no engine and no box API (box/claim.go).
func serveClaim(ctx context.Context, cfg box.Config) error {
	claim := box.NewClaim(cfg)
	srv := &http.Server{
		Addr:              net.JoinHostPort("", strconv.Itoa(cfg.Port)),
		Handler:           claim,
		ReadHeaderTimeout: 15 * time.Second,
	}
	log.Printf("havend %s: no owner yet, claim mode on :%d (open it and enter your npub with the setup code)", cfg.Version, cfg.Port)
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	select {
	case err := <-errc:
		return err
	case <-claim.Done:
	case <-ctx.Done():
	}
	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
	if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
