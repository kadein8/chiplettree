from transformers import MobileViTFeatureExtractor, MobileViTForImageClassification
from PIL import Image
import requests
import torch
import os
# url = "http://images.cocodataset.org/val2017/000000039769.jpg"
# image = Image.open(requests.get(url, stream=True).raw)
# ---------------------- 核心修改：本地图片路径配置 ----------------------
# 1. 替换为你的本地JPG图片路径（支持相对路径或绝对路径）
# 相对路径：图片放在代码运行目录下，直接写文件名（如 "test.jpg"）
# 绝对路径：完整路径（如 Windows "C:/images/photo.jpg" | Linux/macOS "/home/user/images/photo.jpg"）
local_image_path = "./000000039769.jpg"  # 示例：当前目录下的 "local_test.jpg"

# ---------------------- 图片加载与校验 ----------------------
def load_local_jpg(image_path):
    """
    加载本地JPG图片，包含路径校验和异常处理
    :param image_path: 本地图片路径（str）
    :return: PIL.Image 对象
    """
    # 1. 校验路径是否存在
    if not os.path.exists(image_path):
        raise FileNotFoundError(f"错误：本地图片路径不存在 → {image_path}\n请检查路径是否正确，或图片是否已放在指定位置")
    
    # 2. 校验文件是否为JPG格式（通过后缀名初步判断）
    valid_extensions = [".jpg", ".jpeg"]  # 包含JPEG的常见后缀
    file_ext = os.path.splitext(image_path)[-1].lower()
    if file_ext not in valid_extensions:
        raise ValueError(f"错误：文件格式不是JPG/JPEG → 后缀为 {file_ext}\n请选择扩展名为 .jpg 或 .jpeg 的图片文件")
    
    # 3. 加载图片（处理PIL可能抛出的读取异常）
    try:
        image = Image.open(image_path).convert("RGB")  # 强制转为RGB（避免灰度图/透明通道问题）
        print(f"✅ 成功加载本地图片：{image_path}")
        print(f"   图片尺寸：{image.size}（宽×高） | 图片模式：{image.mode}")
        return image
    except Exception as e:
        raise RuntimeError(f"错误：加载图片时失败 → {str(e)}\n可能原因：图片文件损坏、权限不足")
image=load_local_jpg(local_image_path)
print("image loading ok")

feature_extractor = MobileViTFeatureExtractor.from_pretrained("./",local_files_only=True)
model = MobileViTForImageClassification.from_pretrained("./",local_files_only=True)

inputs = feature_extractor(images=image, return_tensors="pt")
print("inputs prepared")

print("model",model)

outputs = model(**inputs)
logits = outputs.logits

# model predicts one of the 1000 ImageNet classes
predicted_class_idx = logits.argmax(-1).item()
print("Predicted class:", model.config.id2label[predicted_class_idx])
