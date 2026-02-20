#include <iostream>
#include <opencv2/opencv.hpp>
#include <thread>
#include <atomic>
#include <mutex>

using namespace std;
using namespace cv;

std::thread videoThread;
std::atomic<bool> stopFlag(false);
Mat latestFrame;
std::mutex frameMutex;

extern "C" {
    void runVideoCapture() {
        VideoCapture cap(0, CAP_V4L2);
        if (!cap.isOpened()) {
            cout << "No video stream detected" << endl;
            return;
        }

        // Request the camera's native MJPEG format — this avoids the costly
        // YUYV -> BGR -> JPEG conversion path and lets the camera deliver
        // pre-compressed frames directly to OpenCV.
        cap.set(CAP_PROP_FOURCC, VideoWriter::fourcc('M', 'J', 'P', 'G'));
        cap.set(CAP_PROP_FRAME_WIDTH, 1280);
        cap.set(CAP_PROP_FRAME_HEIGHT, 720);
        cap.set(CAP_PROP_FPS, 30);

        Mat frame;
        while (!stopFlag.load()) {
            cap >> frame;
            if (frame.empty()) {
                continue;
            }
            {
                std::lock_guard<std::mutex> lock(frameMutex);
                latestFrame = frame.clone();
            }
        }
        cap.release();
    }

    void startVideoCaptureInThread() {
        stopFlag = false;
        videoThread = std::thread(runVideoCapture);
    }

    void stopVideoCapture() {
        stopFlag = true;
        if (videoThread.joinable()) {
            videoThread.join();
        }
    }

    uint8_t* getLatestFrameBytes(int* length) {
        if (!length) {
            return nullptr;
        }

        *length = 0;

        Mat frameCopy;
        {
            std::lock_guard<std::mutex> lock(frameMutex);
            if (latestFrame.empty()) {
                return nullptr;
            }
            frameCopy = latestFrame.clone();
        }

        vector<uint8_t> buf;
        vector<int> params = { IMWRITE_JPEG_QUALITY, 85 };
        if (!imencode(".jpg", frameCopy, buf, params) || buf.empty()) {
            return nullptr;
        }

        *length = static_cast<int>(buf.size());
        uint8_t* data = new uint8_t[*length];
        if (!data) {
            return nullptr;
        }

        memcpy(data, buf.data(), *length);
        return data;
    }
}