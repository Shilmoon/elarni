package main

import (
	"context"
	"runtime"

	"github.com/xtls/libxray/share"
)

type fetchRequest = share.SubscriptionFetchRequest

func fetchFeed(request fetchRequest) (any, error) {
	request.DeviceOS, request.DeviceVersion, request.DeviceModel = runtime.GOOS, deviceVersion(), "PC"
	switch runtime.GOOS {
	case "windows":
		request.DeviceOS = "Windows"
	case "linux":
		request.DeviceOS = "Linux"
	case "darwin":
		request.DeviceOS, request.DeviceModel = "macOS", "Mac"
	}
	return share.FetchSubscription(context.Background(), request)
}
