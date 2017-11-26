//
//  ViewController.swift
//  GestureDemo
//
//  Created by Sena Odabaşı on 23.11.2017.
//  Copyright © 2017 Sena Odabaşı. All rights reserved.
//

import UIKit

class ViewController: UIViewController, UIGestureRecognizerDelegate {
    
    @IBOutlet weak var area: UIView!
    @IBOutlet weak var panGestureRecognizer: UIPanGestureRecognizer!
    @IBOutlet weak var swipeGestureRecognizer: UISwipeGestureRecognizer!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        self.panGestureRecognizer.require(toFail: self.swipeGestureRecognizer)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    @IBAction func tapDetected(_ sender: UITapGestureRecognizer) {
        self.area.transform = CGAffineTransform.identity
    }
    
    @IBAction func swipeRecognized(_ sender: UISwipeGestureRecognizer) {
        changeColor()
    }
    
    func changeColor(){
        self.area.backgroundColor = UIColor(red:
            CGFloat(arc4random_uniform(255))/255.0, green:CGFloat(arc4random_uniform(255))/255.0, blue:CGFloat(arc4random_uniform(255))/255.0, alpha: 1)
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
        
    }
    
    @IBAction func rotationDetected(_ sender: UIRotationGestureRecognizer) {
        self.area.transform = self.area.transform.rotated(by: sender.rotation)
        sender.rotation = 0
    }
    
    @IBAction func pinchDetected(_ sender: UIPinchGestureRecognizer) {
        self.area.transform = self.area.transform.scaledBy(x: sender.scale, y: sender.scale)
        sender.scale = 1
    }
    
    @IBAction func panRecognized(_ sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: self.view)
        self.area.transform = self.area.transform.translatedBy(x: translation.x, y: translation.y)
        
        sender.setTranslation(CGPoint.zero, in: self.view)
    }
    
}

