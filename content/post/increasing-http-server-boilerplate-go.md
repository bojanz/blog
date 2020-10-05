---
author: "Bojan Zivanovic"
date: 2020-10-02
title: Increasing http.Server boilerplate
slug: "increasing-http-server-boilerplate-go"
---

One great feature of Go is the built-in http.Server. It allows each app to serve HTTP and HTTPS traffic without having to put a reverse proxy such as Nginx in front of it.

At a glance the API is simple:
```c
http.ListenAndServe(":8080", h)
```
where *h* is http.ServeMux or a third party router such as [Chi](https://github.com/go-chi/chi). But as always, the devil is in the details.
Handling these details will require some boilerplate, so let's start writing it.

### Production-ready configuration (timeouts, TLS)

[ListenAndServe](https://golang.org/src/net/http/server.go?s=97511:97566#L3108) creates an http.Server and uses it to listen on the given address and serve the given handler:
```c
func ListenAndServe(addr string, handler Handler) error {
	server := &Server{Addr: addr, Handler: handler}
	return server.ListenAndServe()
}
```
However, the instantiated http.Server is not production ready. It is missing important timeouts which can lead
to resource exhaustion. The TLS configuration is optimized neither for speed nor security. All of this is covered in a famous blog post by Cloudflare titled [So you want to expose Go on the Internet](https://blog.cloudflare.com/exposing-go-on-the-internet/).

So, how does a well configured server look according to Cloudflare?
```c
func NewServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:    addr,
		Handler: handler,
		// https://blog.cloudflare.com/exposing-go-on-the-internet/
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
		TLSConfig: &tls.Config{
			NextProtos:       []string{"h2", "http/1.1"},
			MinVersion:       tls.VersionTLS12,
			CurvePreferences: []tls.CurveID{tls.CurveP256, tls.X25519},
			CipherSuites: []uint16{
				tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
				tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
				tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,
				tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,
				tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
				tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			},
			PreferServerCipherSuites: true,
		}
}
```

Usage stays similar:
```c
server := NewServer(":8080", r)
server.ListenAndServe()
```

Our next step is to allow the server to (optionally) listen on a systemd socket.

### Systemd

There are two broad ways in which a Go app is deployed: containerized or native.

A containerized app is put in a container and then deployed to the cloud, which can be anything
from a Kubernetes setup to an IaaS provider like [Heroku](https://www.heroku.com/) or [Platform.sh](https://platform.sh/).  
However, not every deployment needs the complexity that the containerized approach brings. 
One can get very far with a single VPS or dedicated server. I am a strong believer in continuing to support
the "$5 Digital Ocean" crowd, especially now that Go has given us extra performance compared to the old PHP days.

A native deployment usually means Linux, which is nowadays powered by [systemd](https://www.digitalocean.com/community/tutorials/systemd-essentials-working-with-services-units-and-the-journal). Systemd will automatically start our app and bind it to the specified port, restart on failure, and redirect
logs from stderr to syslog or [journald](https://sematext.com/blog/journald-logging-tutorial/). When redeploying our app, during the 1-2s downtime window, systemd will queue up any incoming requests, ensuring zero downtime deploys.

This sounds great, but it requires a bit of adaptation on our side. Aside from having to ship two systemd config files
(a unit file and a socket file), the app also needs to be able to listen on a systemd socket.

Let's assume that *addr* defaults to a TCP address such as ":8080", but can also
be set to a systemd socket name such as "systemd:myapp-http", preferably through an
environment variable which can be defined in our unit file.

With a little help from [coreos/go-systemd](https://github.com/coreos/go-systemd), a helper is born:
```c
func Listen(addr string) (net.Listener, error) {
	var ln net.Listener
	if strings.HasPrefix(addr, "systemd:") {
		name := addr[8:]
		listeners, _ := activation.ListenersWithNames()
		listener, ok := listeners[name]
		if !ok {
			return nil, fmt.Errorf("listen systemd %s: socket not found", name)
		}
		ln = listener[0]
	} else {
		var err error
		ln, err = net.Listen("tcp", addr)
		if err != nil {
			return nil, err
		}
	}

	return ln, nil
}
```

Usage now looks like this:
```c
addr := os.GetEnv("LISTEN")
if addr == "" {
	addr = ":8080"
}
server := NewServer(addr, r)
ln, err := Listen(addr)
if err != nil { 
	// Handle the error.
}
server.Serve(ln)
```

Having to pass *addr* twice and call *Listen()* ourselves is a bit tedious.
Let's define our own Server struct which embeds *\*http.Server*, and move the listener logic there:
```c
package httpx

type Server struct {
	*http.Server
}

func NewServer(addr string, handler http.Handler) *Server {}

func (srv *Server) Listen() (net.Listener, error) {
	// Same code as before, but now using srv.Addr
}

func (srv *Server) ListenAndServe() error {
	ln, err := srv.Listen()
	if err != nil {
		return err
	}
	return srv.Serve(ln)
}

func (srv *Server) ListenAndServeTLS(certFile, keyFile string) error {
	ln, err := srv.Listen()
	if err != nil {
		return err
	}
	return srv.ServeTLS(ln, certFile, keyFile)
}
```

Usage is now simple again:
```c
addr := os.GetEnv("LISTEN")
if addr == "" {
	addr = ":8080"
}
server := NewServer(addr, r)
server.ListenAndServe()
```

### TLS

Don't we live in an HTTPS world? So far we've used *ListenAndServe* and *Serve*, not *ListenAndServeTLS* and *ServeTLS*.
Can we just add those three missing letters, point to the certificate, modify the port, and call it a day?

Yes, if we're just serving an API. But if we're serving HTML, we still need both HTTP and HTTPS, otherwise we won't be
able to visit our URL via the browser without supplying the HTTPS port. The job of the HTTP server is to redirect
users to the HTTPS resource.

That redirect logic looks like this:
```c
type httpRedirectHandler struct{}

func (h httpRedirectHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil {
		// No port found.
		host = r.Host
	}
	r.URL.Host = host
	r.URL.Scheme = "https"

	w.Header().Set("Connection", "close")
	http.Redirect(w, r, r.URL.String(), http.StatusMovedPermanently)
}
```

Each *Serve* call is blocking, so the two servers must run in their own goroutines.
Both goroutines need to complete, and the idiomatic way to do that is using a [WaitGroup](https://golang.org/pkg/sync/#WaitGroup):
```c
mainServer := NewServer(":443", r)
redirectServer := NewServer(":80", httpRedirectHandler{})

wg := sync.WaitGroup{}
wg.Add(2)
go func() {
	mainServer.ListenAndServeTLS(certFile, keyFile)
	wg.Done()
}()
go func() {
	redirectServer.ListenAndServe()
	wg.Done()
}()

wg.Wait()
```
There's only one detail missing now: error handling.
If one of the servers errors out (couldn't bind to addr or load the certificate) 
we want to make sure the other one is immediately stopped, and execution stops.

Ideally we'd get the error from *wg.Wait*, but it doesn't support that.
The answer lies in [x/sync/errgroup](https://pkg.go.dev/golang.org/x/sync/errgroup), which builds upon WaitGroup and does just that, in only 60 lines of code.

Here's our code with error handling:
```c
mainServer := NewServer(":443", r)
redirectServer := NewServer(":80", httpRedirectHandler{})

g, ctx := errgroup.WithContext(context.Background())
g.Go(func() error {
	if err := mainServer.ListenAndServeTLS(certFile, keyFile); err != http.ErrServerClosed {
		return err
	}
	return nil
})
g.Go(func() error {
	if err := redirectServer.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
})
go func() {
	// The context is closed if both servers finish, or one of them
	// errors out, in which case we want to close the other and return.
	<-ctx.Done()
	mainServer.Close()
	redirectServer.Close()
}()

err := g.Wait() 
```
Note how we distinguish a real error from *http.ErrServerClosed*. 
We don't want to call *Close* for *http.ErrServerClosed* because it would interfere with graceful shutdown.

The next tweak is more subjective. I dislike the fact that *certFile* and *keyFile* are passed
when starting the server and not when initializing it. I would prefer having one way to start
the server regardless of whether it uses TLS or not.

Let's add a few more helpers to httpx:
```c
func NewServerTLS(addr string, cert tls.Certificate, handler http.Handler) *Server {
	srv := NewServer(addr, handler)
	srv.TLSConfig.Certificates = []tls.Certificate{cert}

	return srv
}

func (srv *Server) IsTLS() bool {
	return len(srv.TLSConfig.Certificates) > 0 || srv.TLSConfig.GetCertificate != nil
}

func (srv *Server) Start() error {
	ln, err := srv.Listen()
	if err != nil {
		return err
	}
	if srv.IsTLS() {
		ln = tls.NewListener(ln, srv.TLSConfig)
	}
	return srv.Serve(ln)
}
```

Our final implementation now looks like this:
```c
cert, err := tls.LoadX509KeyPair(certFile, keyFile)
if err != nil {
	// Log the error and stop here.
}
mainServer := NewServerTLS(":443", cert, r)
redirectServer := NewServer(":80", httpRedirectHandler{})

g, ctx := errgroup.WithContext(context.Background())
g.Go(func() error {
	if err := mainServer.Start(); err != http.ErrServerClosed {
		return err
	}
	return nil
})
g.Go(func() error {
	if err := redirectServer.Start(); err != http.ErrServerClosed {
		return err
	}
	return nil
})
go func() {
	// The context is closed if both servers finish, or one of them
	// errors out, in which case we want to close the other and return.
	<-ctx.Done()
	mainServer.Close()
	redirectServer.Close()
}()

err := g.Wait() 
```

### Graceful shutdown

We have talked about how to start the servers, but not how to shut them down.
When a shutdown signal is received (SIGINT or SIGTERM), we want to shut down the servers in the opposite order from
which we started them, first the redirect server then the main server. This will allow any in progress requests
to complete:

```c
redirectTimeout := 1 * time.Second
ctx, cancel := context.WithTimeout(context.Background(), redirectTimeout)
defer cancel()
if err := redirectServer.Shutdown(ctx); err == context.DeadlineExceeded {
	return fmt.Errorf("%v timeout exceeded while waiting on HTTP shutdown", redirectTimeout)
}
mainTimeout := 5 * time.Second
ctx, cancel := context.WithTimeout(context.Background(), mainTimeout)
defer cancel()
if err := mainServer.Shutdown(ctx); err == context.DeadlineExceeded {
	return fmt.Errorf("%v timeout exceeded while waiting on HTTPS shutdown", mainTimeout)
}
```

It is tempting to make each Server responsible for catching the shutdown signal and shutting down automatically, but that would make it impossible to control the shutdown order. So, no new helpers here.
Instead, I like to create an Application struct, with its own Start() and Shutdown() methods containing the code shown here. In addition to starting and shutting down servers, these methods can also handle app-specific workers such as queue processors.

The main package is then the one responsible for tying it all together:
```c
	// Initialize dependencies, pass them to the Application.
	logger := NewLogger()
	app := myapp.New(logger)

	// Wait for shut down in a separate goroutine.
	errCh := make(chan error)
	go func() {
		shutdownCh := make(chan os.Signal)
		signal.Notify(shutdownCh, os.Interrupt, syscall.SIGTERM)
		<-shutdownCh

		errCh <- app.Shutdown()
	}()

	// Start the server and handle any errors.
	if err := app.Start(); err != nil {
		logger.Fatal().Msg(err.Error())
	}
	// Handle shutdown errors.
	if err := <-errCh; err != nil {
		logger.Warn().Msg(err.Error())
	}
```

### Conclusion
A simple microservice deployed to a known place can keep its code simple. A larger
and more generic app needs more boilerplate. Luckily, it's a problem that is easy to solve.

I have gathered the httpx code shared here and published it as [bojanz/httpx](https://github.com/bojanz/httpx).
The README has working examples of systemd unit and socket files.
The code itself is only a hundred lines long (without comments), so I encourage those unenthusiastic about introducing another dependency to just copy
the code into their project. After all, a little copying is better than a little dependency.
