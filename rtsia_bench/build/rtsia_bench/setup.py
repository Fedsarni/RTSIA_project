from setuptools import setup

package_name = 'rtsia_bench'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='RTSIA team',
    maintainer_email='you@example.com',
    description='SemIf vs generative LLM latency benchmark on Jetson AGX Orin',
    license='MIT',
    entry_points={
        'console_scripts': [
            'sensor_sim = rtsia_bench.sensor_sim:main',
            'semif_node = rtsia_bench.semif_node:main',
            'llm_gen_node = rtsia_bench.llm_gen_node:main',
            'logger = rtsia_bench.logger:main',
        ],
    },
)
